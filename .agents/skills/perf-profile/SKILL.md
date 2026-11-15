---
name: perf-profile
description: Use for ad-hoc CPU profiling with Linux perf
---

# Ad-hoc perf profiling

Run `perf` normally. Avoid launching workloads as root. Kernel-symbol access is
already configured.

Setup (only read on error): <../../../nixos/mods/perf.nix>

## Capture

Start with software `cpu-clock` (on-CPU time), 199 Hz, frame pointers:

```bash
perf record -N -e cpu-clock -F 199 -g -o "tmp/perf.data" -- COMMAND ARGS
perf report --stdio -i "tmp/perf.data"
```

For an existing same-UID PID, replace the record command with:

```bash
timeout --foreground --preserve-status --signal=INT 10 \
  perf record -N -e cpu-clock -F 199 -g -o "tmp/perf.data" -p PID
```

Launch inherits CAP_SYSLOG. Attach leaves target capabilities unchanged. Keep
`-N` to avoid build-ID cache writes. Check stderr/lost samples. Use
`--no-children -g none` for a compact self-time report.

- User-only: `-e cpu-clock:u -g --user-callchains`.
- Missing FP: replace `-g` with `--call-graph dwarf,16384`. Larger stack copies
  cost more; increase only if stacks truncate.

## Offline flamegraph

Use perf's bundled Python exporter and self-contained HTML template:

```bash
perf script -i "tmp/perf.data" \
  -s "$(perf --exec-path)/scripts/python/flamegraph.py" -- \
  -i "tmp/perf.data" -o "tmp/flamegraph.html"
```

## Diagnose errors

- Access: check `type -a perf`, `id`, and `getcap "$(command -v perf)"`
  (`pkgsUnstable.libcap`). Check for PATH shadowing, e.g. from `nix shell`.
  Expected: paranoid=1, kptr_restrict=1.
- Symbols: `perf buildid-list -i DATA`, `readelf -S BINARY`
  (`pkgsUnstable.binutils`). Nixpkgs C/Rust usually retain FP + symbols.
  Overrides/prebuilt binaries may not. Rust `strip=symbols` and Go `-s -w`
  strip useful symbols. Installed split debug info only covers builds that
  produce it.
- Archives: live kernel maps describe this boot. Module/JIT maps can change
  sooner. Export before reboot or save matching kallsyms for `--kallsyms`.
  Preserve matching ELF/debug outputs against Nix GC.

## Improve this skill

After profiling, update this skill with generalizable insights, verified fixes,
and reusable workflows discovered during the task. Exclude workload- specific
findings, transient failures, and session history. Keep it concise; revise
stale guidance instead of accumulating caveats.
