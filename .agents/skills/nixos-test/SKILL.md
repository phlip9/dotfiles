---
name: nixos-test
description: Use when writing, refactoring, optimizing, or debugging NixOS VM and container tests in nixos/tests/
---

# NixOS VM and container tests

Write, refactor, optimize, and debug fast, deterministic, hermetic tests in
`nixos/tests/`.

The intention behind our extensive NixOS tests is to e2e test the functionality
that we actually depend on in production (i.e., `sauna` and `phlipdesk`
machines). High quality, well-maintained tests allow us to upgrade NixOS
frequently and fearlessly.

## Harness & commands

Entry point: `nixos/tests/default.nix` (`runNixOSTest`)
- Auto-imports all `nixos/mods/` NixOS modules
- configures `openssh` + deterministic ed25519 host key
- configures `sops.defaultSopsFile = ./fixtures/secrets.yaml`
- injects `nixos/tests/lib/testlib/` via `extraPythonPackages`

```bash
# Run a test
uptime && nix build -f . nixosTests.<name> --no-link -L && uptime
# Add --rebuild to force a fresh run for timing/repeatability
nix build -f . nixosTests.<name> --no-link --rebuild -L

# Fmt + lint (driver checks testScript w/ ty/ruff only at build time).
just nix-ci
# python-ci checks testlib/ and standalone *.py on both Linux and macOS.
just python-ci
```

- Driver `testScript` runs at module scope: `nonlocal` is a SyntaxError at top
  level; mutate a list/dict (`last_up[:] = ...`) or use `global`.

## 1. Pick the cheapest test tier for a test

Push pure logic and edge cases down before booting a machine:

1. Offline sandbox derivation: rules, routing, config checks, jq/Go/Py unit
   tests, or even a short-lived local daemon (`o11y-alerting-unit.nix` +
   `o11y-alerting-unit/inhibition.py`, `just/grafana.jq.test`,
   `nixos/pkgs/nixos-exporter/main_test.go`). Runs in `<1s`.
2. NixOS container (`containers.<name>`): default for module wiring, systemd
   units/hardening, networking, sockets, TLS, multi-node protocols (`o11y*`,
   `paseo`, `rbitcoin`, `github-*`). Boots in ~4-7s.
3. NixOS VM (`nodes.<name>`): ONLY when the guest needs its own kernel or
   VM-only features. Always justify with a `# why VM: ...` comment. We know
   these require a VM test:
   - initrd, LUKS, kernel keyring, tty/console, setuid PAM
     (`desktop-login.nix`)
   - writable `/nix/store` for guest `nix build` (`nixbot.nix`)
   - eBPF, perf events, kernel sysctls (`o11y-profiling-ebpf.nix`)
   - ...

VM defaults to remember:
- Size `virtualisation.cores` / `memorySize` deliberately (e.g. `2` for
  parallel boot, `4` when CPU-spinning workloads compete w/ daemons).
- Offline VMs running `nix` MUST set `nix.settings.substituters = lib.mkForce [
  ];` or Nix stalls ~4s per build/check retrying unreachable caches.

## 2. Write hermetic, high-signal tests

### Use shared `testlib`

Import from `testlib` (`nixos/tests/lib/testlib/__init__.py`) and
`testlib.o11y` (`nixos/tests/lib/testlib/o11y.py`):

| helper | purpose |
|---|---|
| `CURL` / `CURL_QUIET` | bounded curl (`--connect-timeout 2 --max-time 10`) |
| `CMD_TIMEOUT` / `WAIT_TIMEOUT` / `UP_TIMEOUT` | standard `timedelta` bounds (15s / 30s / 60s) |
| `wait_for_cmd` / `wait_for_port` / `wait_for_http` | fast back-to-back drop-ins (no 1s driver sleep) |
| `wait_for_value` / `wait_fast` | back-to-back predicate polling (return value or bool) |
| `batch_requests` | N `(url, method)` checks in one `curl -K -` (reuses TLS/HTTP2) |
| `dump_evidence` | bounded diagnostic dump on exception |
| `vm_flush` / `vm_query` / `vm_labels` / `wait_for_vm_labels` | VictoriaMetrics flush + PromQL helpers |
| `metrics_scrape` / `metric_sum` | Prometheus text scrape + filtered sum |
| `pyro_post` / `pyro_fn_names` / `pyro_label_values` / `pyro_window` | Pyroscope Connect API w/ transient retry |

Promote new reusable helpers into `nixos/tests/lib/testlib/` (fully typed,
verified w/ `just python-ci`) rather than duplicating across tests. Spend the
extra effort to refactor and improve existing helpers so all tests benefit.

### Hermetic fixtures & stand-ins

- Secrets: pass `pkgs.writeText` (w/ trailing `\n` like sops files) to `*File`
  options and disable `services.openssh.enable = lib.mkForce false` when sops
  itself isn't under test. Use `./fixtures/secrets.yaml` when testing sops
  decryption.
- External APIs: write e.g. tiny `phlipPkgs.writeTypedPython3Bin` loopback
  stand-ins (`ThreadingHTTPServer`, `LOCK`, JSONL request log in
  `StateDirectory`, silent `log_message`), or protocol-real local servers
  (`versitygw` for S3, `lib/o11y-ingest.nix` for self-signed TLS + `htpasswd`).
- Closure hygiene: copy single fixture files out of large packages via
  `pkgs.runCommand` so full upstream source trees don't enter the test closure.
- Atomic probe output: guest probes/fakes writing files for `wait_for_file`
  must write to `<path>.tmp` and `os.replace` / `mv` so readers never see
  partial JSON.
- Real boundaries: use non-1000 UIDs to catch hardcoded `/run/user/1000`; put
  test dirs outside `/tmp` for services w/ `PrivateTmp`; test auth/socket
  denials from outside as unprivileged users (`runuser -u ...`).

### Prove invariants, avoid vacuous assertions

- Prove positive before asserting negative: confirm the event/flush happened
  before asserting `not seen` or `== 0` (sentinel metric written after rejected
  writes, scoped `inhibitedBy` fingerprint + suppression counter, confirmed
  delivery before asserting no leak).
- Assert exact sets, lengths, and status codes:
  - Check raw list length + exact set on scraped/returned items (job-keyed
    dicts silently drop duplicates or unexpected down targets).
  - Assert exact HTTP codes (`401`/`403`/`404`) w/ bounded curl, not bare
    `machine.fail`.
  - Before asserting "only loopback listeners", assert every expected port is
    present (`ss -Hltun`, numeric `-n`).
- Mutation-check regression tests: temporarily break the behavior or revert the
  patch, confirm the new assertion fails, then restore.

## 3. Systemd & `systemd-nspawn` gotchas

- `Type=simple` units: `wait_for_unit` succeeds on fork, before sockets bind or
  files exist. Wait on `wait_for_port` (`ss -Hltn`, always numeric `-n`, since
  `-t` resolves `:443` -> `:https`) or `wait_for_http` on `/health` /
  `/-/ready`.
- Path/event-activated targets: `wait_for_unit` fails fast if a unit is
  inactive w/ no pending job. Poll `wait_for_cmd(node, "systemctl is-active
  <target>")` when only a `.path` unit starts it.
- `systemctl show` property order: `--value` prints properties in systemd's
  internal order, NOT CLI flag order. Drop `--value` and parse `key=val` lines
  into a dict.
- Periodic timers: override `OnCalendar = lib.mkForce "2099-01-01 00:00:00"` in
  test config instead of stopping the timer at runtime (runtime `stop` leaves
  already-enqueued jobs + boot-time runs in the journal; `lib.mkForce null`
  emits empty `OnCalendar=` which disables the timer unit). Scope journal
  assertions w/ `_SYSTEMD_INVOCATION_ID=<id>`.
- Multi-container cgroups: sibling `nspawn` containers share host cgroupfs.
  Give stopped/restarted services distinct `Slice =
  "${config.networking.hostName}.slice"` so stopping one node cannot race
  another's cgroup cleanup.
- Container sandbox limits:
  - No setuid wrappers: use `runuser` not `su`; for lingering `user@.service`
    in containers, override `security.pam.services.systemd-user.rules.account`
    `unix.modulePath` to `pam_permit.so`.
  - No delegated cgroup memory/io controllers in the Nix sandbox: check
    `cpu.stat` for per-unit cgroup metrics.
- Hidden `nspawn` boot gate: the driver's initial connection waits for boot
  jobs to finish, incl. `Type=oneshot` units `wantedBy` boot services (e.g.
  `grafana-git-sync-setup.service`). Factor that into boot-floor analysis.

## 4. Optimize systematically

### Measure first, change one thing at a time

1. Run `--rebuild` on low host load (`uptime` before/after; discard noisy runs)
   and save full output to `tmp/<test>-baseline.log`.
2. Extract per-subtest durations, service start timestamps (`Started ...`,
   `HTTP Server Listen`, `Consumed ...s CPU time`), and log lines (`wc -l`).
3. Identify the true cold-start floor (e.g. Grafana ~7s). Work that overlaps
   under the floor costs `0s` on the critical path.
4. Apply one logical optimization at a time, re-measure, and verify `--rebuild`
   repeatability at the end.

### High-leverage speedups

- Kill 1s polling sleeps. Replace driver `wait_until_succeeds`,
  `wait_for_open_port`, and `retry` w/ `testlib` fast polls or event-driven
  waits (`rbitcoin-cli waitforblock`, Alloy `flush?hold=true`). Never use
  `time.sleep`.
- Disable unused services like `services.openssh.enable = lib.mkForce false`,
  `services.grafana.enable = lib.mkForce false`, unused exporters/timers
  (especially oneshots blocking `multi-user.target` like `pyroscope-du`).
- Skip `multi-user.target` when unneeded. Wait on the exact services you need
  first so early subtests run while slower services boot. Don't restart
  services at test end just to leave them running.
- Cut redundant restarts & bloat. Verify static systemd wiring w/ `systemctl
  show` (`WantedBy`, `PartOf`, `Requires`, `After`, `Restart`). Keep at most
  one real crash/recovery test (e.g. `SIGKILL`) when systemd lifecycle behavior
  itself is non-trivial, and let it cover idempotent re-run too. Move pure
  formatting/parsing/CLI cases into offline unit tests.
- Batch HTTP/TLS matrices. For example, collapse loops of status checks into
  one `batch_requests` (`curl -K -`) call.
- Overlap hardened unit starts, since hardened units (`SystemCallFilter`,
  `ProtectSystem=strict`, `DynamicUser`) cost ~1.1-1.3s per start in `nspawn`
  (`sd-executor` setup). Never weaken hardening for speed; instead launch async
  (`systemctl start/restart --no-block`, `systemctl kill --signal=KILL`) and
  run independent subtests while they execute.
  - Join async units by saving `InvocationID` before launch and polling
    `(InvocationID, ActiveState, Result)` via `systemctl show` (`key=val`):

```python
# `(InvocationID, ActiveState, Result)` for a systemd unit (quiet `execute`).
def unit_state(unit: str) -> tuple[str, str, str]:
    rc, out = machine.execute(
        f"systemctl show -p InvocationID -p ActiveState -p Result {unit}",
        timeout=CMD_TIMEOUT,
    )
    assert rc == 0, (rc, out)
    props = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    return props["InvocationID"], props["ActiveState"], props["Result"]
```

  - Wait until `inv != prev_inv and state not in ("activating",
    "deactivating")`, fail fast on `state == "failed"`, and assert final state
    (`"inactive"` for normal oneshots, `"active"` for `RemainAfterExit=true`).
- Start slow writes/ingests early. Push initial test metrics, crafted writes,
  or fixture profiles before unrelated subtests so background flushes and
  indexing finish in parallel.

### Time-series & alerting tuning

- Import `./lib/victoriametrics.nix` (`-search.latencyOffset=0s`,
  `-storage.cacheSizeIndexDBTagFilters=1`, `-remoteWrite.flushInterval=100ms`,
  `-promscrape.suppressScrapeErrors`).
- VictoriaMetrics 1s indexdb flush: batch initial new series into one push so
  the ~1s indexdb tick runs once; use `wait_for_vm_labels(...,
  flush_each=False)` when writes already returned 2xx.
- Beware whole-second PromQL queries, as `vmalert` instant queries use integer
  Unix seconds (`time=<sec>`). Stamp pushed samples slightly in the past w/
  monotonic ms increments (`max(ts + 10, (int(time.time()) - 5) * 1000)`) so
  updates are visible on the next `100ms` eval without waiting for the next
  second boundary.
- Lowering eval intervals shrinks derived timeouts (e.g. `vmalert` alert expiry
  = `4 * max(interval, resendDelay)`). Pin `"rule.resendDelay" = "1s"` when
  using `interval = "100ms"`, and use `"group.maxStartDelay" = "1ms"` (`0s`
  panics in `vmalert`).
- Range-query grid and `rate()`. Match panel `queryOptions.interval` to test
  `scrape_interval` (default 15s step misses samples if a fast test finishes
  inside one `:00/:15/:30/:45` bucket), and gate `rate()` assertions on
  `count_over_time(...[5m]) >= 2`.
- Prefer test knobs like `groupWait = "0s"`, `groupInterval = "100ms"`,
  `NIXBOT_METRICS_CACHE_TTL = "0"`, `NIKS3_INVENTORY_REFRESH_INTERVAL = "1s"`,
  `testHooks = true`.

## 5. Debug cleanly & keep logs readable

- Always wrap `testScript` in `try: ... except Exception:
  dump_evidence(EVIDENCE); raise` to aid debugging.
  - Include targeted `journalctl --no-pager -o cat -u <svc> | tail -n N`,
    relevant API snapshots (`/api/v1/targets`, `/api/v1/rules`,
    `/api/v2/alerts`, filtered `/metrics`), `ss -Hltunp`, and sink logs.
  - Bound every `curl` (`CURL`) and guest command (`CMD_TIMEOUT`) so hangs fail
    their step and still run `dump_evidence` instead of hitting
    `globalTimeout`.
  - Record last observed state in `wait_for_value` / `wait_fast` closures and
    include it in timeout errors.
  - Fail fast on permanent errors inside poll predicates (`ActiveState ==
    "failed"`, non-404/409 HTTP codes, count exceeding expected) instead of
    waiting out the full timeout.
- Silence log noise at the source.
  - Use `machine.execute` + explicit `assert rc == 0` inside polled predicates
    (`machine.succeed` logs 2 lines per poll and floods test logs).
  - Silence chatty services via config (`services.phlip9-o11y.server.grafana`
    `logFilters`, `versitygw --quiet`, `vmagent`
    `-promscrape.suppressScrapeErrors`, silent `BaseHTTPRequestHandler`
    `log_message`).
  - Track log line count (`wc -l`) alongside runtime when optimizing.

## 6. Verification checklist

Before committing or presenting changes:

- `just nix-ci` (and `just python-ci` if `testlib/` or any `.py` changed, plus
  relevant offline unit tests like `just grafana-test`, `just go-ci`, `just
  alerting-test`).
- `nix build -f . nixosTests.<name> --no-link --rebuild -L` passes on low load.
- Line width `<= 80` cols (except URLs/tables), `git diff --check` clean, no
  `tmp/` files staged.

## Improve this skill

After writing, optimizing, or debugging a NixOS test, update this skill with
newly discovered generalizable patterns or insights, traps, or `testlib`
additions. Exclude one-off bugs and session history. Revise stale guidance
rather than appending caveats.
