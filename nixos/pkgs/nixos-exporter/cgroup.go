// Per-unit resource usage from the cgroup v2 tree: memory, swap, CPU, IO,
// PSI, and OOM kills of each systemd slice, service, and scope.
// node-exporter has none of these: its systemd collector only reports unit
// state.
//
// Cgroups: every root cgroup, plus every direct child of a root slice, that
// is a slice, service, or scope. Ex: `init.scope`, `system.slice`,
// `system.slice/nginx.service`, `workload.slice/paseo.service`,
// `user.slice/user-1000.slice`. Deeper cgroups (session scopes, a unit's own
// sub-cgroups) roll up into these. Mounts, sockets, and swaps run no
// long-lived processes. A oneshot's cgroup, and so its series, only exists
// while it runs.
//
// Values are hierarchical: a slice includes its children, so don't sum
// across levels. Counters restart from 0 when a unit restarts (new cgroup).
//
// Labels, like systemd's own model (`systemctl show -p Slice <unit>`):
//   - unit: the unit, ex: `paseo.service`. Unit names are unique, so this
//     alone identifies a cgroup. Its path: `<slice>/<unit>`, or `<unit>` for
//     a root cgroup.
//   - slice: the unit's slice. Root cgroups are in `-.slice`, the root slice.
//     So root cgroups: `slice="-.slice"`; one slice's units:
//     `slice="workload.slice"`; units below the root slices:
//     `slice=~".+", slice!="-.slice"` (series from before these labels
//     have no `slice`).
//
// Keep in sync: nixos/sauna/grafana/overview.json "Resources" row + OOM
// kill annotations query these names + labels.
//
// Missing interface files are skipped, not errors: a controller not enabled
// for that cgroup, swap accounting off, PSI disabled (`psi=0`), or a cgroup
// removed mid-scrape.
//
// Example samples (sauna, 2026-11-10, 804 samples over 38 cgroups):
//
//	nixos_cgroup_memory_bytes{slice="-.slice",unit="workload.slice"} 8385507328
//	nixos_cgroup_memory_bytes{slice="workload.slice",unit="paseo.service"} 4109930496
//	nixos_cgroup_memory_stat_bytes{slice="workload.slice",unit="paseo.service",type="anon"} 802414592
//	nixos_cgroup_memory_max_bytes{slice="workload.slice",unit="paseo.service"} 50451218432
//	nixos_cgroup_cpu_seconds_total{slice="workload.slice",unit="paseo.service"} 759.893149
//	nixos_cgroup_io_read_bytes_total{slice="workload.slice",unit="paseo.service",device="md127"} 2568458240
//	nixos_cgroup_pressure_stalled_seconds_total{slice="workload.slice",unit="paseo.service",kind="some",resource="io"} 1.238054
//	nixos_cgroup_oom_kills_total{slice="workload.slice",unit="paseo.service"} 0
//
// Cost (sauna, 38 cgroups, 11 files each): one scrape reads ~420 files in
// ~3ms, w/ ~1,800 syscalls and ~1,500 allocations. The reader reuses one
// buffer and parses only the fields it exports; the writer renders straight
// into the output buffer.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// memory.stat fields exported as `nixos_cgroup_memory_stat_bytes{type}`.
// `anon` + `file_mapped` ~ RSS. `file` is page cache, incl. `shmem` (tmpfs).
var memoryStatTypes = [...]string{
	"anon", "file", "file_mapped", "shmem", "kernel",
}

// PSI resources exported as `nixos_cgroup_pressure_stalled_seconds_total`.
var pressureResources = [...]string{"cpu", "memory", "io"}

// PSI kinds, the line keys of `<resource>.pressure`. some: >= 1 task
// stalled; full: all non-idle tasks stalled.
var pressureKinds = [...]string{"some", "full"}

const (
	// initial read buffer, fits every interface file we read (memory.stat
	// is ~1.6 KiB on Linux 7.3). Grows if needed.
	readBufferSize = 4096

	// rendered size of one cgroup's samples (~2.3 KiB on sauna), to size
	// the output buffer up front.
	bytesPerCgroup = 2560
)

// optionalUint is a value that may be absent: a missing file or field, or
// no limit (`max`).
type optionalUint struct {
	value uint64
	ok    bool
}

// cgroupStats is one cgroup's usage. See the file comment for absent
// values.
type cgroupStats struct {
	// path relative to the cgroup root, ex: `workload.slice/paseo.service`.
	path string
	// `slice="<slice>",unit="<unit>"`, escaped. See `cgroupLabels`.
	label string
	// memory.current: all memory charged, incl. page cache + kernel.
	memory optionalUint
	// memory.stat, by `memoryStatTypes` index.
	memoryStat [len(memoryStatTypes)]optionalUint
	// memory.max
	memoryMax optionalUint
	// memory.swap.current
	swap optionalUint
	// memory.swap.max
	swapMax optionalUint
	// cpu.stat `usage_usec`
	cpuUsecs optionalUint
	// io.stat, per device.
	io []ioStats
	// `<resource>.pressure` total stall usecs, by `pressureResources` +
	// `pressureKinds` index.
	pressure [len(pressureResources)][len(pressureKinds)]optionalUint
	// memory.events `oom_kill`
	oomKills optionalUint
}

// ioStats is one io.stat device line.
type ioStats struct {
	// kernel name, ex: `md127`, or `<major>:<minor>` if unknown. Escaped.
	device     string
	readBytes  uint64
	writeBytes uint64
}

// readCgroups reads the usage of every selected cgroup under `root`.
// `sysDevBlock` (/sys/dev/block) names io.stat's devices.
func readCgroups(root, sysDevBlock string) ([]cgroupStats, error) {
	paths, err := listCgroups(root)
	if err != nil {
		return nil, err
	}

	reader := cgroupReader{
		buf:         make([]byte, readBufferSize),
		sysDevBlock: sysDevBlock,
		deviceNames: map[string]string{},
	}
	stats := make([]cgroupStats, len(paths))
	for idx, path := range paths {
		err := reader.readCgroup(&stats[idx], filepath.Join(root, path))
		if err != nil {
			return nil, fmt.Errorf("cgroup %s: %w", path, err)
		}
		stats[idx].path = path
		stats[idx].label = cgroupLabels(path)
	}
	return stats, nil
}

// cgroupLabels are the labels of the cgroup at `path`: see the file
// comment. Paths are at most 2 deep (see `listCgroups`), so a root cgroup is
// a unit in `-.slice`, and any other is a unit in its root slice.
func cgroupLabels(path string) string {
	slice, unit, nested := strings.Cut(path, "/")
	if !nested {
		slice, unit = "-.slice", path
	}
	return `slice="` + labelEscaper.Replace(slice) +
		`",unit="` + labelEscaper.Replace(unit) + `"`
}

// listCgroups returns the selected cgroups (see the file comment), sorted
// by path.
func listCgroups(root string) ([]string, error) {
	names, err := unitCgroups(root)
	if err != nil {
		return nil, err
	}

	var paths []string
	for _, name := range names {
		paths = append(paths, name)
		if !strings.HasSuffix(name, ".slice") {
			continue
		}

		children, err := unitCgroups(filepath.Join(root, name))
		if errors.Is(err, fs.ErrNotExist) {
			// Removed since we listed the root.
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, child := range children {
			paths = append(paths, name+"/"+child)
		}
	}
	return paths, nil
}

// unitCgroups returns the sorted slice, service, and scope cgroups in `dir`.
// Names only, no stat: interface files never have these suffixes, so a
// match is a cgroup dir.
func unitCgroups(dir string) ([]string, error) {
	file, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	names, err := file.Readdirnames(-1)
	if err != nil {
		return nil, err
	}
	names = slices.DeleteFunc(names, func(name string) bool {
		return !strings.HasSuffix(name, ".slice") &&
			!strings.HasSuffix(name, ".service") &&
			!strings.HasSuffix(name, ".scope")
	})
	slices.Sort(names)
	return names, nil
}

// cgroupReader reads interface files for one scrape. It reuses one buffer
// and calls open/read/close directly: os.ReadFile also fstats each file,
// and os.Open registers it w/ epoll + sets O_NONBLOCK (kernfs files are
// pollable), 9 syscalls per file vs 4.
type cgroupReader struct {
	buf         []byte
	sysDevBlock string
	// io.stat `<major>:<minor>` -> escaped device name.
	deviceNames map[string]string
}

// readCgroup fills `stats` from the interface files in `dir`.
func (reader *cgroupReader) readCgroup(stats *cgroupStats, dir string) error {
	var err error

	// Single-value files.
	singles := []struct {
		name  string
		value *optionalUint
	}{
		{"memory.current", &stats.memory},
		{"memory.max", &stats.memoryMax},
		{"memory.swap.current", &stats.swap},
		{"memory.swap.max", &stats.swapMax},
	}
	for _, single := range singles {
		if *single.value, err = reader.readUint(dir, single.name); err != nil {
			return err
		}
	}

	// Flat-keyed files: `<key> <value>` lines.
	content, err := reader.read(dir + "/memory.stat")
	if err != nil {
		return err
	}
	err = parseKeyed("memory.stat", content, memoryStatTypes[:],
		stats.memoryStat[:])
	if err != nil {
		return err
	}
	if content, err = reader.read(dir + "/cpu.stat"); err != nil {
		return err
	}
	stats.cpuUsecs, err = keyedValue("cpu.stat", content, "usage_usec")
	if err != nil {
		return err
	}
	if content, err = reader.read(dir + "/memory.events"); err != nil {
		return err
	}
	stats.oomKills, err = keyedValue("memory.events", content, "oom_kill")
	if err != nil {
		return err
	}

	// Nested-keyed files: `<key> <field>=<value> ...` lines.
	if stats.io, err = reader.readIOStat(dir); err != nil {
		return err
	}
	for resource, resourceName := range pressureResources {
		name := resourceName + ".pressure"
		if content, err = reader.read(dir + "/" + name); err != nil {
			return err
		}
		err = parseNested(content, func(key, fields []byte) error {
			kind := slices.Index(pressureKinds[:], string(key))
			if kind < 0 {
				return nil
			}
			total, err := nestedField(name, fields, "total")
			if err == nil && !total.ok {
				err = fmt.Errorf("%s: %s: no total", name, key)
			}
			stats.pressure[resource][kind] = total
			return err
		})
		if err != nil {
			return err
		}
	}

	return nil
}

// readIOStat reads io.stat's per-device read + write bytes.
func (reader *cgroupReader) readIOStat(dir string) ([]ioStats, error) {
	content, err := reader.read(dir + "/io.stat")
	if err != nil {
		return nil, err
	}

	var stats []ioStats
	err = parseNested(content, func(key, fields []byte) error {
		device, err := reader.deviceName(key)
		if err != nil {
			return err
		}
		readBytes, err := nestedField("io.stat", fields, "rbytes")
		if err != nil {
			return err
		}
		writeBytes, err := nestedField("io.stat", fields, "wbytes")
		if err != nil {
			return err
		}
		stats = append(stats, ioStats{
			device:     device,
			readBytes:  readBytes.value,
			writeBytes: writeBytes.value,
		})
		return nil
	})
	return stats, err
}

// deviceName resolves a `<major>:<minor>` block device to its escaped
// kernel name (ex: `md127`) via `<sysDevBlock>/<major>:<minor>/uevent`.
// Falls back to the number if the device is gone. Cached for the scrape.
func (reader *cgroupReader) deviceName(number []byte) (string, error) {
	if name, ok := reader.deviceNames[string(number)]; ok {
		return name, nil
	}

	// Not `reader.read`: `number` points into its buffer. Only a few
	// devices per scrape.
	key := string(number)
	uevent, err := os.ReadFile(reader.sysDevBlock + "/" + key + "/uevent")
	if err = missingOr(err); err != nil {
		return "", err
	}
	name := key
	for line := range bytes.Lines(uevent) {
		if value, ok := bytes.CutPrefix(line, []byte("DEVNAME=")); ok {
			name = string(bytes.TrimSpace(value))
		}
	}

	name = labelEscaper.Replace(name)
	reader.deviceNames[key] = name
	return name, nil
}

// readUint reads a single-value file. Absent if missing or `max`.
func (reader *cgroupReader) readUint(dir, name string) (optionalUint, error) {
	content, err := reader.read(dir + "/" + name)
	if err != nil {
		return optionalUint{}, err
	}
	text := bytes.TrimSpace(content)
	if len(text) == 0 || string(text) == "max" {
		return optionalUint{}, nil
	}

	value, err := parseUint(text)
	if err != nil {
		return optionalUint{}, fmt.Errorf("%s: %w", name, err)
	}
	return optionalUint{value: value, ok: true}, nil
}

// read returns a file's content, valid until the next read. Empty if
// missing: ENOENT, or ENODEV (cgroup removed after open), or EOPNOTSUPP
// (PSI disabled).
func (reader *cgroupReader) read(path string) ([]byte, error) {
	fd, err := ignoringEINTR(func() (int, error) {
		return syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC, 0)
	})
	if err != nil {
		return nil, missingOr(&fs.PathError{Op: "open", Path: path, Err: err})
	}
	defer syscall.Close(fd)

	// Read until EOF, doubling the buffer when full.
	size := 0
	for {
		if size == len(reader.buf) {
			reader.buf = append(reader.buf, make([]byte, len(reader.buf))...)
		}
		count, err := ignoringEINTR(func() (int, error) {
			return syscall.Read(fd, reader.buf[size:])
		})
		if err != nil {
			err = &fs.PathError{Op: "read", Path: path, Err: err}
			return nil, missingOr(err)
		}
		if count == 0 {
			return reader.buf[:size], nil
		}
		size += count
	}
}

// missingOr returns nil if `err` means the file is missing, else `err`.
func missingOr(err error) error {
	if errors.Is(err, fs.ErrNotExist) ||
		errors.Is(err, syscall.ENODEV) ||
		errors.Is(err, syscall.EOPNOTSUPP) {
		return nil
	}
	return err
}

// ignoringEINTR retries a syscall interrupted by a signal.
func ignoringEINTR(call func() (int, error)) (int, error) {
	for {
		result, err := call()
		if err != syscall.EINTR {
			return result, err
		}
	}
}

// parseKeyed fills `values[idx]` from the `<keys[idx]> <value>` line of a
// flat-keyed file. Other keys are skipped, unparsed.
func parseKeyed(
	name string, content []byte, keys []string, values []optionalUint,
) error {
	for line := range bytes.Lines(content) {
		key, valueText, ok := bytes.Cut(bytes.TrimSpace(line), []byte(" "))
		if !ok {
			return fmt.Errorf("%s: bad line %q", name, line)
		}
		idx := slices.Index(keys, string(key))
		if idx < 0 {
			continue
		}
		value, err := parseUint(valueText)
		if err != nil {
			return fmt.Errorf("%s: %s: %w", name, key, err)
		}
		values[idx] = optionalUint{value: value, ok: true}
	}
	return nil
}

// keyedValue returns one key's value from a flat-keyed file.
func keyedValue(name string, content []byte, key string) (optionalUint, error) {
	var value [1]optionalUint
	err := parseKeyed(name, content, []string{key}, value[:])
	return value[0], err
}

// parseNested calls `fn` w/ each line of a nested-keyed file: `<key>
// <field>=<value> ...`, ex: io.stat, *.pressure.
func parseNested(content []byte, fn func(key, fields []byte) error) error {
	for line := range bytes.Lines(content) {
		key, fields, _ := bytes.Cut(bytes.TrimSpace(line), []byte(" "))
		if len(key) == 0 {
			continue
		}
		if err := fn(key, fields); err != nil {
			return err
		}
	}
	return nil
}

// nestedField returns `field`'s value from a nested-keyed line's fields.
// Absent if the line has no such field.
func nestedField(
	name string, fields []byte, field string,
) (optionalUint, error) {
	for word := range bytes.FieldsSeq(fields) {
		wordField, valueText, ok := bytes.Cut(word, []byte("="))
		if !ok {
			return optionalUint{}, fmt.Errorf("%s: bad field %q", name, word)
		}
		if string(wordField) != field {
			continue
		}
		value, err := parseUint(valueText)
		if err != nil {
			return optionalUint{}, fmt.Errorf("%s: %s: %w", name, field, err)
		}
		return optionalUint{value: value, ok: true}, nil
	}
	return optionalUint{}, nil
}

// parseUint parses a decimal uint64. The string conversion doesn't escape,
// so it doesn't allocate.
func parseUint(text []byte) (uint64, error) {
	return strconv.ParseUint(string(text), 10, 64)
}

// cgroupFamily is one metric family: HELP, TYPE, and how to emit a cgroup's
// samples.
type cgroupFamily struct {
	name, kind, help string
	samples          func(out *metricWriter, cgroup *cgroupStats)
}

// cgroupFamilies are rendered in this order.
var cgroupFamilies = [...]cgroupFamily{
	{
		"nixos_cgroup_memory_bytes", "gauge",
		"Memory charged to the cgroup, incl. page cache + kernel " +
			"(memory.current). What MemoryMax limits.",
		func(out *metricWriter, cgroup *cgroupStats) {
			out.optional(cgroup, cgroup.memory)
		},
	},
	{
		"nixos_cgroup_memory_stat_bytes", "gauge",
		"Memory breakdown (memory.stat). anon + file_mapped ~ RSS; " +
			"file is page cache, incl. shmem.",
		func(out *metricWriter, cgroup *cgroupStats) {
			for idx, statType := range memoryStatTypes {
				out.optional(cgroup, cgroup.memoryStat[idx],
					`,type="`, statType, `"`)
			}
		},
	},
	{
		"nixos_cgroup_memory_max_bytes", "gauge",
		"Memory limit, i.e. MemoryMax (memory.max). Absent if unlimited.",
		func(out *metricWriter, cgroup *cgroupStats) {
			out.optional(cgroup, cgroup.memoryMax)
		},
	},
	{
		"nixos_cgroup_memory_swap_bytes", "gauge",
		"Swap used (memory.swap.current).",
		func(out *metricWriter, cgroup *cgroupStats) {
			out.optional(cgroup, cgroup.swap)
		},
	},
	{
		"nixos_cgroup_memory_swap_max_bytes", "gauge",
		"Swap limit, i.e. MemorySwapMax (memory.swap.max). Absent if " +
			"unlimited.",
		func(out *metricWriter, cgroup *cgroupStats) {
			out.optional(cgroup, cgroup.swapMax)
		},
	},
	{
		"nixos_cgroup_cpu_seconds_total", "counter",
		"CPU time used (cpu.stat usage_usec).",
		func(out *metricWriter, cgroup *cgroupStats) {
			if cgroup.cpuUsecs.ok {
				out.seconds(cgroup, cgroup.cpuUsecs.value)
			}
		},
	},
	{
		"nixos_cgroup_io_read_bytes_total", "counter",
		"Bytes read per block device (io.stat rbytes). Stacked " +
			"devices count twice, ex: md127 + its nvme disks.",
		func(out *metricWriter, cgroup *cgroupStats) {
			for _, device := range cgroup.io {
				out.uint(cgroup, device.readBytes,
					`,device="`, device.device, `"`)
			}
		},
	},
	{
		"nixos_cgroup_io_write_bytes_total", "counter",
		"Bytes written per block device (io.stat wbytes). Stacked " +
			"devices count twice, ex: md127 + its nvme disks.",
		func(out *metricWriter, cgroup *cgroupStats) {
			for _, device := range cgroup.io {
				out.uint(cgroup, device.writeBytes,
					`,device="`, device.device, `"`)
			}
		},
	},
	{
		"nixos_cgroup_pressure_stalled_seconds_total", "counter",
		"PSI stall time (<resource>.pressure total). some: >= 1 task " +
			"stalled; full: all non-idle tasks stalled.",
		func(out *metricWriter, cgroup *cgroupStats) {
			for resource, resourceName := range pressureResources {
				for kind, kindName := range pressureKinds {
					total := cgroup.pressure[resource][kind]
					if total.ok {
						out.seconds(cgroup, total.value,
							`,kind="`, kindName,
							`",resource="`, resourceName, `"`)
					}
				}
			}
		},
	},
	{
		"nixos_cgroup_oom_kills_total", "counter",
		"Processes the kernel OOM killer killed in the cgroup or its " +
			"descendants (memory.events oom_kill).",
		func(out *metricWriter, cgroup *cgroupStats) {
			out.optional(cgroup, cgroup.oomKills)
		},
	},
}

// writeCgroupMetrics renders every cgroup metric family, one HELP + TYPE
// each. Families w/o samples are left out.
func writeCgroupMetrics(buf *bytes.Buffer, cgroups []cgroupStats) {
	buf.Grow(len(cgroups) * bytesPerCgroup)
	out := metricWriter{buf: buf}
	for _, family := range cgroupFamilies {
		out.start(family.name, family.kind, family.help)
		for idx := range cgroups {
			family.samples(&out, &cgroups[idx])
		}
		out.end()
	}
}

// metricWriter renders one metric family at a time straight into `buf`:
// HELP + TYPE, then its samples.
type metricWriter struct {
	buf *bytes.Buffer
	// the current family
	name string
	// buf offsets of the current family's header + first sample.
	headerAt, samplesAt int
	// formats a sample value w/o allocating.
	scratch [32]byte
}

// start writes a family's HELP + TYPE.
func (out *metricWriter) start(name, kind, help string) {
	out.name = name
	out.headerAt = out.buf.Len()
	fmt.Fprintf(out.buf, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind)
	out.samplesAt = out.buf.Len()
}

// end drops the current family's header if it got no samples.
func (out *metricWriter) end() {
	if out.buf.Len() == out.samplesAt {
		out.buf.Truncate(out.headerAt)
	}
}

// optional writes a sample if the value is present.
func (out *metricWriter) optional(
	cgroup *cgroupStats, value optionalUint, labels ...string,
) {
	if value.ok {
		out.uint(cgroup, value.value, labels...)
	}
}

// uint writes an integer sample.
func (out *metricWriter) uint(
	cgroup *cgroupStats, value uint64, labels ...string,
) {
	out.write(cgroup, strconv.AppendUint(out.scratch[:0], value, 10), labels)
}

// seconds writes a microseconds sample as seconds, w/o losing precision.
func (out *metricWriter) seconds(
	cgroup *cgroupStats, usecs uint64, labels ...string,
) {
	value := strconv.AppendUint(out.scratch[:0], usecs/1e6, 10)
	value = append(value, '.')
	fraction := usecs % 1e6
	for digit := uint64(1e5); digit > 0; digit /= 10 {
		value = append(value, byte('0'+fraction/digit%10))
	}
	out.write(cgroup, value, labels)
}

// write writes `<name>{<cgroup label><labels>} <value>`. `labels` are
// pieces of extra `,name="value"` pairs, values already escaped.
func (out *metricWriter) write(
	cgroup *cgroupStats, value []byte, labels []string,
) {
	out.buf.WriteString(out.name)
	out.buf.WriteByte('{')
	out.buf.WriteString(cgroup.label)
	for _, label := range labels {
		out.buf.WriteString(label)
	}
	out.buf.WriteString("} ")
	out.buf.Write(value)
	out.buf.WriteByte('\n')
}

// labelEscaper escapes a label value for the text exposition format.
// systemd escapes `-` in unit names as `\x2d`, so backslashes are common.
var labelEscaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)
