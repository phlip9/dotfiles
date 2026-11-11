package main

import (
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

// addCgroup creates a cgroup dir (relative to the cgroup root) w/ the given
// interface files.
func (host *fakeHost) addCgroup(path string, files map[string]string) {
	host.t.Helper()
	host.mkdir(filepath.Join("cgroup", path))
	for name, content := range files {
		host.writeFile(
			filepath.Join(host.paths.cgroupRoot, path, name), content,
		)
	}
}

// TestCgroupMetrics verifies which cgroups get exported, every metric of a
// fully populated cgroup, missing files, and label escaping.
func TestCgroupMetrics(t *testing.T) {
	host := newFakeHost(t)

	// Root cgroup's own files + non-unit cgroups: all skipped.
	host.writeFile(
		filepath.Join(host.paths.cgroupRoot, "cgroup.procs"), "1\n",
	)
	host.addCgroup("dev-hugepages.mount", map[string]string{
		"memory.current": "1\n",
	})
	host.addCgroup("system.slice/boot.mount", map[string]string{
		"memory.current": "1\n",
	})

	// Only cpu.stat, like a root cgroup w/o controllers enabled.
	host.addCgroup("init.scope", map[string]string{
		"cpu.stat": "usage_usec 2500000\nuser_usec 2000000\n" +
			"system_usec 500000\n",
	})

	// A slice w/ limits.
	host.addCgroup("workload.slice", map[string]string{
		"memory.current":  "4096\n",
		"memory.max":      "8192\n",
		"memory.swap.max": "max\n",
	})

	// Every interface file, like a real service. memory.stat outgrows the
	// initial read buffer.
	var statPadding strings.Builder
	for idx := 0; statPadding.Len() <= readBufferSize; idx++ {
		fmt.Fprintf(&statPadding, "padding_%d %d\n", idx, idx)
	}
	host.addCgroup("workload.slice/paseo.service", map[string]string{
		"memory.current": "500\n",
		"memory.stat": statPadding.String() +
			"anon 300\nfile 150\nkernel 50\nkernel_stack 8\n" +
			"file_mapped 20\nshmem 5\nsock 0\n",
		"memory.max":          "max\n",
		"memory.swap.current": "7\n",
		"memory.swap.max":     "4096\n",
		"cpu.stat": "usage_usec 1234567\nuser_usec 1\n" +
			"system_usec 1\n",
		"io.stat": "9:127 rbytes=10 wbytes=20 rios=1 wios=2 dbytes=0 dios=0\n" +
			"259:0 rbytes=5 wbytes=6 rios=1 wios=1 dbytes=0 dios=0\n",
		"memory.pressure": "some avg10=0.00 avg60=0.00 total=1500\n" +
			"full avg10=0.00 avg60=0.00 total=500\n",
		"memory.events": "low 0\nhigh 0\nmax 3\noom 1\noom_kill 1\n" +
			"oom_group_kill 0\n",
	})
	// 9:127 has a name; 259:0 is gone, so it keeps its number.
	host.mkdir("dev-block/9:127")
	host.writeFile(
		filepath.Join(host.paths.sysDevBlock, "9:127", "uevent"),
		"MAJOR=9\nMINOR=127\nDEVNAME=md127\nDEVTYPE=disk\n",
	)

	// Deeper cgroups roll up into their parent: skipped.
	host.addCgroup("user.slice/user-1000.slice", map[string]string{
		"memory.current": "64\n",
	})
	host.addCgroup("user.slice/user-1000.slice/session-1.scope",
		map[string]string{"memory.current": "32\n"})

	// systemd escapes `-` as `\x2d` in unit names.
	host.addCgroup(`system.slice/systemd-fsck@dev-disk-by\x2duuid.service`,
		map[string]string{"memory.current": "1\n"})

	body := host.mustScrape()
	got := map[string]string{}
	for name, value := range samples(t, body) {
		if strings.HasPrefix(name, "nixos_cgroup_") {
			got[name] = value
		}
	}

	// `nixos_cgroup_<name>{<labels>}`, a key of `got`.
	key := func(name string, labels ...string) string {
		return "nixos_cgroup_" + name + "{" + strings.Join(labels, ",") + "}"
	}
	// A cgroup's labels: root cgroups are units in `-.slice`.
	labels := func(slice, unit string) string {
		return `slice="` + slice + `",unit="` + unit + `"`
	}
	initScope := labels("-.slice", "init.scope")
	workload := labels("-.slice", "workload.slice")
	user := labels("user.slice", "user-1000.slice")
	paseo := labels("workload.slice", "paseo.service")
	fsck := labels("system.slice",
		`systemd-fsck@dev-disk-by\\x2duuid.service`)
	want := map[string]string{
		key("cpu_seconds_total", initScope): "2.500000",

		key("memory_bytes", workload):     "4096",
		key("memory_max_bytes", workload): "8192",
		key("memory_bytes", user):         "64",
		key("memory_bytes", fsck):         "1",

		key("memory_bytes", paseo):                            "500",
		key("memory_stat_bytes", paseo, `type="anon"`):        "300",
		key("memory_stat_bytes", paseo, `type="file"`):        "150",
		key("memory_stat_bytes", paseo, `type="file_mapped"`): "20",
		key("memory_stat_bytes", paseo, `type="shmem"`):       "5",
		key("memory_stat_bytes", paseo, `type="kernel"`):      "50",
		key("memory_swap_bytes", paseo):                       "7",
		key("memory_swap_max_bytes", paseo):                   "4096",
		key("cpu_seconds_total", paseo):                       "1.234567",
		key("io_read_bytes_total", paseo, `device="md127"`):   "10",
		key("io_write_bytes_total", paseo, `device="md127"`):  "20",
		key("io_read_bytes_total", paseo, `device="259:0"`):   "5",
		key("io_write_bytes_total", paseo, `device="259:0"`):  "6",
		key("oom_kills_total", paseo):                         "1",
		key("pressure_stalled_seconds_total", paseo,
			`kind="some"`, `resource="memory"`): "0.001500",
		key("pressure_stalled_seconds_total", paseo,
			`kind="full"`, `resource="memory"`): "0.000500",
	}
	for name, value := range want {
		if got[name] != value {
			t.Errorf("%s: expected %q, got %q", name, value, got[name])
		}
	}
	for name := range got {
		if _, ok := want[name]; !ok {
			t.Errorf("unexpected sample %s", name)
		}
	}

	// One HELP + TYPE per family, and only for families w/ samples.
	for _, family := range []string{
		"nixos_cgroup_memory_bytes",
		"nixos_cgroup_pressure_stalled_seconds_total",
	} {
		if count := strings.Count(body, "# TYPE "+family+" "); count != 1 {
			t.Errorf("%s: expected 1 TYPE line, got %d", family, count)
		}
	}
}

// TestCgroupReadError verifies an unreadable interface file fails the
// scrape, instead of silently dropping the cgroup.
func TestCgroupReadError(t *testing.T) {
	host := newFakeHost(t)
	// A dir where a file should be: read fails w/ EISDIR, even as root.
	host.mkdir("cgroup/system.slice/nginx.service/memory.current")

	status, body := host.scrape(1)
	if status != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", status, body)
	}
	if !strings.Contains(body, "system.slice/nginx.service") {
		t.Fatalf("unexpected error body: %s", body)
	}
}
