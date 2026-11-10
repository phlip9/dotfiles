// nixos-exporter is a Prometheus exporter for NixOS host facts that
// node-exporter can't see: boots, the system profile generation, the last
// activation, whether a reboot would change the kernel, and per-unit
// resource usage.
//
// Metrics (GET /metrics, computed on every scrape):
//   - nixos_boots_total: boots counted since the exporter's state was
//     created. Never resets, independent of the wall clock.
//   - nixos_system_generation: the system profile's generation, i.e. the
//     default boot entry.
//   - nixos_system_switch_timestamp_seconds: mtime of /run/current-system,
//     i.e. the last boot or `switch-to-configuration`.
//   - nixos_reboot_required: 1 if a reboot would boot a different kernel,
//     initrd, kernel modules, or kernel params.
//   - nixos_cgroup_*{cgroup}: memory, swap, CPU, IO, PSI, and OOM kills per
//     systemd slice, service, and scope. See cgroup.go.
//
// Example scrape (sauna, 2026-11-10, fresh state dir, w/o nixos_cgroup_*):
//
//	$ curl -s http://127.0.0.1:9101/metrics
//	# HELP nixos_boots_total Boots counted since the exporter's state was created.
//	# TYPE nixos_boots_total counter
//	nixos_boots_total 1
//	# HELP nixos_system_generation Generation of the system profile, i.e. the default boot entry.
//	# TYPE nixos_system_generation gauge
//	nixos_system_generation 86
//	# HELP nixos_system_switch_timestamp_seconds Last time /run/current-system changed, i.e. a boot or activation.
//	# TYPE nixos_system_switch_timestamp_seconds gauge
//	nixos_system_switch_timestamp_seconds 1794295393.034
//	# HELP nixos_reboot_required 1 if a reboot would change the kernel, initrd, kernel modules, or kernel params.
//	# TYPE nixos_reboot_required gauge
//	nixos_reboot_required 0
//
// Boot counting: on startup, the exporter compares the kernel's boot_id
// against the one in its state file. On a new boot_id it increments the
// count and atomically persists both. Restarts within a boot don't count.
// systemd starts the exporter at boot, so boots that never got scraped
// still count.
//
// Environment variables:
//   - STATE_DIRECTORY (required): set by systemd `StateDirectory=`
//
// Socket activation: systemd LISTEN_FDS/LISTEN_PID (fd 3). The service needs
// no network access of its own.
//
// See also:
//   - nixos/mods/o11y/nixos-exporter.nix
//   - nixos/tests/o11y.nix
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	// state file name in $STATE_DIRECTORY.
	stateFileName = "boots"

	// timeout for reading a scrape request's headers.
	readHeaderTimeout = 10 * time.Second

	// timeout for draining in-flight scrapes on shutdown.
	shutdownTimeout = 5 * time.Second
)

// files the reboot check compares between the booted system and the system
// profile. `kernel`, `initrd`, `kernel-modules` are symlinks into the store,
// like nixpkgs' `system.autoUpgrade.allowReboot` check. `kernel-params` is a
// regular file: param changes also only apply after a reboot.
var (
	rebootSymlinks = []string{"kernel", "initrd", "kernel-modules"}
	rebootFiles    = []string{"kernel-params"}
)

// paths are the host paths the exporter reads. Overridden in tests.
type paths struct {
	// the kernel's random per-boot UUID.
	bootID string
	// persisted `<count> <boot_id>` of the last counted boot.
	stateFile string
	// the system profile, a symlink to `<name>-<generation>-link`.
	systemProfile string
	// the active system, replaced on every boot and activation.
	currentSystem string
	// the system the kernel booted.
	bootedSystem string
	// the cgroup v2 hierarchy.
	cgroupRoot string
	// `<major>:<minor>` -> block device, to name io.stat's devices.
	sysDevBlock string
}

// defaultPaths returns the real host paths.
func defaultPaths(stateDir string) paths {
	return paths{
		bootID:        "/proc/sys/kernel/random/boot_id",
		stateFile:     filepath.Join(stateDir, stateFileName),
		systemProfile: "/nix/var/nix/profiles/system",
		currentSystem: "/run/current-system",
		bootedSystem:  "/run/booted-system",
		cgroupRoot:    "/sys/fs/cgroup",
		sysDevBlock:   "/sys/dev/block",
	}
}

// bootState is the state file's content.
type bootState struct {
	count  uint64
	bootID string
}

func main() {
	if err := run(); err != nil {
		log.Fatalf("nixos-exporter: %v", err)
	}
}

// run counts this boot, then serves /metrics until SIGTERM/SIGINT.
func run() error {
	stateDir := os.Getenv("STATE_DIRECTORY")
	if stateDir == "" {
		return errors.New("STATE_DIRECTORY is not set")
	}
	hostPaths := defaultPaths(stateDir)

	boots, err := countBoot(hostPaths)
	if err != nil {
		return fmt.Errorf("count boot: %w", err)
	}

	listener, err := openSystemdListener()
	if err != nil {
		return fmt.Errorf("open systemd listener: %w", err)
	}

	server := &http.Server{
		Handler:           newHandler(hostPaths, boots),
		ReadHeaderTimeout: readHeaderTimeout,
	}

	// Graceful shutdown on SIGTERM (systemd stop) or SIGINT.
	ctx, stop := signal.NotifyContext(
		context.Background(), syscall.SIGTERM, syscall.SIGINT,
	)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(
			context.Background(), shutdownTimeout,
		)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()

	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// opens LISTEN_FDS fd=3 from systemd socket activation.
func openSystemdListener() (net.Listener, error) {
	if os.Getenv("LISTEN_FDS") != "1" {
		return nil, fmt.Errorf("LISTEN_FDS is not 1")
	}
	if os.Getenv("LISTEN_PID") != strconv.Itoa(os.Getpid()) {
		return nil, fmt.Errorf("LISTEN_PID does not match")
	}

	file := os.NewFile(uintptr(3), "systemd-listen-fd")
	if file == nil {
		return nil, fmt.Errorf("fd 3 unavailable")
	}

	listener, err := net.FileListener(file)
	if err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("wrap fd 3: %w", err)
	}

	return listener, nil
}

// countBoot returns the boot count, first incrementing + persisting it if
// this is a new boot. Idempotent within a boot.
func countBoot(hostPaths paths) (uint64, error) {
	bootIDBytes, err := os.ReadFile(hostPaths.bootID)
	if err != nil {
		return 0, err
	}
	bootID := strings.TrimSpace(string(bootIDBytes))
	if bootID == "" {
		return 0, fmt.Errorf("%s: empty", hostPaths.bootID)
	}

	// No state file yet: this is the first counted boot.
	state, err := readState(hostPaths.stateFile)
	if errors.Is(err, fs.ErrNotExist) {
		state = bootState{}
	} else if err != nil {
		// Never silently reset: a reset count breaks `delta()` queries.
		return 0, err
	}

	if state.bootID == bootID {
		return state.count, nil
	}

	state = bootState{count: state.count + 1, bootID: bootID}
	if err := writeState(hostPaths.stateFile, state); err != nil {
		return 0, err
	}
	log.Printf("counted boot %d (boot_id %s)", state.count, bootID)
	return state.count, nil
}

// readState parses the `<count> <boot_id>\n` state file.
func readState(path string) (bootState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return bootState{}, err
	}

	fields := strings.Fields(string(data))
	if len(fields) != 2 {
		return bootState{}, fmt.Errorf("%s: want `<count> <boot_id>`", path)
	}
	count, err := strconv.ParseUint(fields[0], 10, 64)
	if err != nil {
		return bootState{}, fmt.Errorf("%s: bad count: %w", path, err)
	}

	return bootState{count: count, bootID: fields[1]}, nil
}

// writeState atomically replaces the state file: write + fsync a temp file,
// rename over the old one, fsync the dir. A crash leaves either the old or
// the new state, never a partial one.
func writeState(path string, state bootState) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, stateFileName+".tmp*")
	if err != nil {
		return err
	}
	// No-op after a successful rename.
	defer os.Remove(tmp.Name())

	if _, err := fmt.Fprintf(tmp, "%d %s\n", state.count, state.bootID); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return err
	}

	dirFile, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer dirFile.Close()
	return dirFile.Sync()
}

// newHandler serves GET /metrics, 404 for anything else.
func newHandler(hostPaths paths, boots uint64) http.Handler {
	mux := http.NewServeMux()
	// No `GET /metrics` pattern: `just go-test` runs w/ GO111MODULE=off,
	// which falls back to the pre-1.22 mux that has no method patterns.
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodGet && req.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		body, err := renderMetrics(hostPaths, boots)
		if err != nil {
			// Fail the whole scrape: `up` goes 0, which is alertable, vs
			// a silently missing series.
			log.Printf("scrape: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = w.Write(body)
	})
	return mux
}

// renderMetrics reads the host state and renders it in the Prometheus text
// exposition format.
func renderMetrics(hostPaths paths, boots uint64) ([]byte, error) {
	generation, err := systemGeneration(hostPaths.systemProfile)
	if err != nil {
		return nil, fmt.Errorf("system generation: %w", err)
	}

	// Lstat: the symlink's own mtime, set when activation replaces it.
	currentInfo, err := os.Lstat(hostPaths.currentSystem)
	if err != nil {
		return nil, fmt.Errorf("current system: %w", err)
	}
	switchTime := currentInfo.ModTime()

	rebootRequired, err := rebootRequired(
		hostPaths.bootedSystem, hostPaths.systemProfile,
	)
	if err != nil {
		return nil, fmt.Errorf("reboot required: %w", err)
	}

	cgroups, err := readCgroups(hostPaths.cgroupRoot, hostPaths.sysDevBlock)
	if err != nil {
		return nil, fmt.Errorf("cgroups: %w", err)
	}

	var buf bytes.Buffer
	writeMetric(&buf, "nixos_boots_total", "counter",
		"Boots counted since the exporter's state was created.",
		strconv.FormatUint(boots, 10))
	writeMetric(&buf, "nixos_system_generation", "gauge",
		"Generation of the system profile, i.e. the default boot entry.",
		strconv.FormatUint(generation, 10))
	writeMetric(&buf, "nixos_system_switch_timestamp_seconds", "gauge",
		"Last time /run/current-system changed, i.e. a boot or activation.",
		strconv.FormatFloat(
			float64(switchTime.UnixNano())/1e9, 'f', 3, 64,
		))
	writeMetric(&buf, "nixos_reboot_required", "gauge",
		"1 if a reboot would change the kernel, initrd, kernel modules, or "+
			"kernel params.",
		boolMetric(rebootRequired))
	writeCgroupMetrics(&buf, cgroups)
	return buf.Bytes(), nil
}

// writeMetric appends one unlabeled sample w/ its HELP + TYPE lines.
func writeMetric(buf *bytes.Buffer, name, kind, help, value string) {
	fmt.Fprintf(buf, "# HELP %s %s\n# TYPE %s %s\n%s %s\n",
		name, help, name, kind, name, value)
}

// boolMetric renders a bool as a 0/1 sample value.
func boolMetric(value bool) string {
	if value {
		return "1"
	}
	return "0"
}

// systemGeneration parses the generation out of the profile's
// `<name>-<generation>-link` symlink target.
func systemGeneration(profile string) (uint64, error) {
	target, err := os.Readlink(profile)
	if err != nil {
		return 0, err
	}

	name := regexp.QuoteMeta(filepath.Base(profile))
	linkRe := regexp.MustCompile("^" + name + `-(\d+)-link$`)
	match := linkRe.FindStringSubmatch(filepath.Base(target))
	if match == nil {
		return 0, fmt.Errorf("%s -> %s: not a generation link", profile, target)
	}
	return strconv.ParseUint(match[1], 10, 64)
}

// rebootRequired reports whether the next boot (the system profile) has a
// different kernel, initrd, kernel modules, or kernel params than the
// booted system. A file missing from both is equal: container systems
// (`boot.isContainer`) have no kernel.
func rebootRequired(bootedSystem, systemProfile string) (bool, error) {
	for _, name := range rebootSymlinks {
		booted, err := readlinkOptional(filepath.Join(bootedSystem, name))
		if err != nil {
			return false, err
		}
		next, err := readlinkOptional(filepath.Join(systemProfile, name))
		if err != nil {
			return false, err
		}
		if booted != next {
			return true, nil
		}
	}

	for _, name := range rebootFiles {
		booted, err := readFileOptional(filepath.Join(bootedSystem, name))
		if err != nil {
			return false, err
		}
		next, err := readFileOptional(filepath.Join(systemProfile, name))
		if err != nil {
			return false, err
		}
		if booted != next {
			return true, nil
		}
	}

	return false, nil
}

// optionalValue is a file's content or symlink target, or absent. Comparable
// w/ `==`.
type optionalValue struct {
	exists bool
	value  string
}

// readlinkOptional is os.Readlink, but a missing link is absent, not an
// error.
func readlinkOptional(path string) (optionalValue, error) {
	target, err := os.Readlink(path)
	if errors.Is(err, fs.ErrNotExist) {
		return optionalValue{}, nil
	}
	if err != nil {
		return optionalValue{}, err
	}
	return optionalValue{exists: true, value: target}, nil
}

// readFileOptional is os.ReadFile, but a missing file is absent, not an
// error.
func readFileOptional(path string) (optionalValue, error) {
	content, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return optionalValue{}, nil
	}
	if err != nil {
		return optionalValue{}, err
	}
	return optionalValue{exists: true, value: string(content)}, nil
}
