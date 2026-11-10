package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeHost is a temp dir laid out like a NixOS host: a boot_id file, a
// state dir, two system toplevels in a fake store, the system profile,
// /run/{current,booted}-system, and an empty cgroup tree.
type fakeHost struct {
	t     *testing.T
	root  string
	paths paths
}

// newFakeHost boots generation 1 (`sys-a`), then activates it.
func newFakeHost(t *testing.T) *fakeHost {
	t.Helper()
	root := t.TempDir()
	host := &fakeHost{
		t:    t,
		root: root,
		paths: paths{
			bootID:        filepath.Join(root, "boot_id"),
			stateFile:     filepath.Join(root, "state", stateFileName),
			systemProfile: filepath.Join(root, "profiles", "system"),
			currentSystem: filepath.Join(root, "run", "current-system"),
			bootedSystem:  filepath.Join(root, "run", "booted-system"),
			cgroupRoot:    filepath.Join(root, "cgroup"),
			sysDevBlock:   filepath.Join(root, "dev-block"),
		},
	}
	for _, dir := range []string{
		"state", "profiles", "run", "store", "cgroup", "dev-block",
	} {
		host.mkdir(dir)
	}

	host.setBootID("boot-1")
	host.addSystem("sys-a", "kernel-a", "params-a")
	host.setProfile(1, "sys-a")
	host.symlink(host.store("sys-a"), host.paths.bootedSystem)
	host.symlink(host.store("sys-a"), host.paths.currentSystem)
	return host
}

// store returns a path in the fake store.
func (host *fakeHost) store(name string) string {
	return filepath.Join(host.root, "store", name)
}

// mkdir creates a dir under the fake root.
func (host *fakeHost) mkdir(rel string) {
	host.t.Helper()
	if err := os.MkdirAll(filepath.Join(host.root, rel), 0o755); err != nil {
		host.t.Fatal(err)
	}
}

// symlink atomically (re)points `link` at `target`, like `ln -sfn`.
func (host *fakeHost) symlink(target, link string) {
	host.t.Helper()
	tmp := link + ".tmp"
	if err := os.Symlink(target, tmp); err != nil {
		host.t.Fatal(err)
	}
	if err := os.Rename(tmp, link); err != nil {
		host.t.Fatal(err)
	}
}

// writeFile writes a file under the fake root.
func (host *fakeHost) writeFile(path, content string) {
	host.t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		host.t.Fatal(err)
	}
}

// setBootID fakes a (re)boot's new kernel boot_id.
func (host *fakeHost) setBootID(bootID string) {
	host.writeFile(host.paths.bootID, bootID+"\n")
}

// addSystem creates a system toplevel w/ the given kernel + params.
// `kernel` also names the initrd + modules, like a real kernel bump.
func (host *fakeHost) addSystem(name, kernel, params string) {
	host.t.Helper()
	host.mkdir(filepath.Join("store", name))
	toplevel := host.store(name)
	host.symlink(host.store(kernel)+"/bzImage", filepath.Join(toplevel, "kernel"))
	host.symlink(host.store(kernel)+"-initrd/initrd", filepath.Join(toplevel, "initrd"))
	host.symlink(host.store(kernel)+"-modules", filepath.Join(toplevel, "kernel-modules"))
	host.writeFile(filepath.Join(toplevel, "kernel-params"), params)
}

// setProfile adds generation `generation` -> `system` and makes it the
// profile's default, like `nix-env --profile ... --set`.
func (host *fakeHost) setProfile(generation int, system string) {
	profiles := filepath.Dir(host.paths.systemProfile)
	link := fmt.Sprintf("system-%d-link", generation)
	host.symlink(host.store(system), filepath.Join(profiles, link))
	host.symlink(link, host.paths.systemProfile)
}

// serve runs the exporter's server on a loopback listener until the test
// ends. Returns its `http://<addr>`.
func (host *fakeHost) serve(boots uint64) string {
	host.t.Helper()
	return host.serveTimeout(boots, connTimeout)
}

// serveTimeout is serve w/ a per-connection timeout.
func (host *fakeHost) serveTimeout(
	boots uint64, timeout time.Duration,
) string {
	host.t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		host.t.Fatal(err)
	}
	host.t.Cleanup(func() { listener.Close() })
	server := metricsServer{
		hostPaths: host.paths, boots: boots, timeout: timeout,
	}
	// Returns once the listener closes.
	go server.serve(listener)
	return "http://" + listener.Addr().String()
}

// scrape GETs /metrics and returns the status + body.
func (host *fakeHost) scrape(boots uint64) (int, string) {
	host.t.Helper()
	resp, err := http.Get(host.serve(boots) + "/metrics")
	if err != nil {
		host.t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		host.t.Fatal(err)
	}
	return resp.StatusCode, string(body)
}

// samples parses a scrape body into `name -> value`, skipping comments.
func samples(t *testing.T, body string) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(body), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		name, value, ok := strings.Cut(line, " ")
		if !ok {
			t.Fatalf("bad sample line %q", line)
		}
		out[name] = value
	}
	return out
}

// mustCountBoot runs countBoot and checks the count.
func mustCountBoot(t *testing.T, host *fakeHost, want uint64) {
	t.Helper()
	got, err := countBoot(host.paths)
	if err != nil {
		t.Fatalf("countBoot: %v", err)
	}
	if got != want {
		t.Fatalf("expected boot count %d, got %d", want, got)
	}
}

// TestCountBoot verifies the count only increments on a new boot_id and
// survives restarts via the state file.
func TestCountBoot(t *testing.T) {
	host := newFakeHost(t)

	// First start ever: boot 1.
	mustCountBoot(t, host, 1)
	// Restarts within the same boot don't count.
	mustCountBoot(t, host, 1)
	mustCountBoot(t, host, 1)

	// New boot.
	host.setBootID("boot-2")
	mustCountBoot(t, host, 2)
	mustCountBoot(t, host, 2)

	state, err := os.ReadFile(host.paths.stateFile)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(state), "2 boot-2\n"; got != want {
		t.Fatalf("expected state %q, got %q", want, got)
	}

	// No leftover temp files.
	entries, err := os.ReadDir(filepath.Dir(host.paths.stateFile))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected only the state file, got %v", entries)
	}
}

// TestCountBootRejectsBadState verifies a corrupt state file fails startup
// instead of silently resetting the count.
func TestCountBootRejectsBadState(t *testing.T) {
	for _, state := range []string{"", "garbage\n", "x boot-1\n", "1 a b\n"} {
		host := newFakeHost(t)
		host.writeFile(host.paths.stateFile, state)
		if _, err := countBoot(host.paths); err == nil {
			t.Fatalf("state %q: expected error", state)
		}
	}
}

// TestMetrics verifies every metric across a deploy that only changes
// userspace, then one that changes the kernel, then one that changes the
// kernel params.
func TestMetrics(t *testing.T) {
	host := newFakeHost(t)

	status, body := host.scrape(7)
	if status != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", status, body)
	}
	if !strings.Contains(body, "# TYPE nixos_boots_total counter\n") {
		t.Fatalf("missing TYPE line:\n%s", body)
	}
	// No cgroups: no cgroup families, not even HELP + TYPE.
	if strings.Contains(body, "nixos_cgroup_") {
		t.Fatalf("unexpected cgroup metrics:\n%s", body)
	}
	got := samples(t, body)
	if got["nixos_boots_total"] != "7" ||
		got["nixos_system_generation"] != "1" ||
		got["nixos_reboot_required"] != "0" {
		t.Fatalf("unexpected samples: %v", got)
	}

	// The switch timestamp is the current-system symlink's own mtime.
	info, err := os.Lstat(host.paths.currentSystem)
	if err != nil {
		t.Fatal(err)
	}
	wantSwitch := fmt.Sprintf("%.3f", float64(info.ModTime().UnixNano())/1e9)
	if got["nixos_system_switch_timestamp_seconds"] != wantSwitch {
		t.Fatalf("expected switch timestamp %s, got %s",
			wantSwitch, got["nixos_system_switch_timestamp_seconds"])
	}

	// Userspace-only deploy: new generation, same kernel.
	host.addSystem("sys-b", "kernel-a", "params-a")
	host.setProfile(2, "sys-b")
	got = samples(t, host.mustScrape())
	if got["nixos_system_generation"] != "2" || got["nixos_reboot_required"] != "0" {
		t.Fatalf("userspace deploy: unexpected samples: %v", got)
	}

	// Kernel bump: a reboot is required.
	host.addSystem("sys-c", "kernel-c", "params-a")
	host.setProfile(3, "sys-c")
	got = samples(t, host.mustScrape())
	if got["nixos_system_generation"] != "3" || got["nixos_reboot_required"] != "1" {
		t.Fatalf("kernel bump: unexpected samples: %v", got)
	}

	// Kernel params change only: also a reboot.
	host.addSystem("sys-d", "kernel-a", "params-d")
	host.setProfile(4, "sys-d")
	got = samples(t, host.mustScrape())
	if got["nixos_reboot_required"] != "1" {
		t.Fatalf("kernel params: unexpected samples: %v", got)
	}

	// Rollback to the booted kernel + params: no reboot.
	host.setProfile(5, "sys-a")
	got = samples(t, host.mustScrape())
	if got["nixos_system_generation"] != "5" || got["nixos_reboot_required"] != "0" {
		t.Fatalf("rollback: unexpected samples: %v", got)
	}
}

// TestRebootRequiredContainer verifies container systems, which have no
// kernel, initrd, or modules: equal when absent from both, a reboot once
// only one side has them.
func TestRebootRequiredContainer(t *testing.T) {
	host := newFakeHost(t)
	host.mkdir("store/container-a")
	host.mkdir("store/container-b")
	host.symlink(host.store("container-a"), host.paths.bootedSystem)
	host.setProfile(2, "container-b")

	required, err := rebootRequired(host.paths.bootedSystem, host.paths.systemProfile)
	if err != nil {
		t.Fatalf("rebootRequired: %v", err)
	}
	if required {
		t.Fatal("expected no reboot between two kernel-less systems")
	}

	// The next system gains a kernel.
	host.addSystem("sys-e", "kernel-e", "")
	host.setProfile(3, "sys-e")
	required, err = rebootRequired(host.paths.bootedSystem, host.paths.systemProfile)
	if err != nil {
		t.Fatalf("rebootRequired: %v", err)
	}
	if !required {
		t.Fatal("expected a reboot once only one side has a kernel")
	}
}

// mustScrape scrapes and fails the test on a non-200 response.
func (host *fakeHost) mustScrape() string {
	host.t.Helper()
	status, body := host.scrape(1)
	if status != http.StatusOK {
		host.t.Fatalf("expected 200, got %d: %s", status, body)
	}
	return body
}

// TestMetricsFailsScrape verifies a broken host path fails the scrape (so
// `up` goes 0) instead of silently dropping a series.
func TestMetricsFailsScrape(t *testing.T) {
	host := newFakeHost(t)
	host.symlink("not-a-generation", host.paths.systemProfile)

	status, body := host.scrape(1)
	if status != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", status, body)
	}
	if !strings.Contains(body, "not a generation link") {
		t.Fatalf("unexpected error body: %s", body)
	}
}

// TestSystemGeneration verifies only `<name>-<digits>-link` targets parse.
func TestSystemGeneration(t *testing.T) {
	host := newFakeHost(t)
	cases := map[string]uint64{"system-89-link": 89, "system-0-link": 0}
	for target, want := range cases {
		host.symlink(target, host.paths.systemProfile)
		got, err := systemGeneration(host.paths.systemProfile)
		if err != nil || got != want {
			t.Errorf("%s: expected %d, got %d, %v", target, want, got, err)
		}
	}

	// The prefix is the profile's own name.
	other := filepath.Join(filepath.Dir(host.paths.systemProfile), "other")
	host.symlink("other-5-link", other)
	if got, err := systemGeneration(other); err != nil || got != 5 {
		t.Errorf("other-5-link: expected 5, got %d, %v", got, err)
	}

	for _, target := range []string{
		"system", "system-89", "system-link", "system--link", "other-89-link",
		"system--89-link", "system-+89-link", "system-8x9-link",
		"system-89-link-link", "system-99999999999999999999-link",
	} {
		host.symlink(target, host.paths.systemProfile)
		if got, err := systemGeneration(host.paths.systemProfile); err == nil {
			t.Errorf("%s: expected error, got %d", target, got)
		}
	}
}
