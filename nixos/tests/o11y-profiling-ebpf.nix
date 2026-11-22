# Exercise whole-host eBPF profiling in one NixOS VM.
# why VM: eBPF and perf events need the guest kernel.
#
#   Alloy   -> nginx (HTTPS) -> Pyroscope
#   vmagent -> nginx (HTTPS) -> VictoriaMetrics
#
# - Collection: non-root Alloy capabilities, symbolized frames, unit labels.
# - Regressions: off-CPU probe lifetime, exited targets, and PID fan-out.
# - Delivery: authenticated profile pushes, batching, and scrape metrics.
#
# Push through the VM's own ingress to exercise remote collector config.
# see: nixos/tests/o11y-ingest.nix
let
  # Units for steady profiles, exit attribution, and short-lived PIDs.
  unit = "ebpf-target";
  exitedUnit = "ebpf-exited";
  forkUnit = "ebpf-forker";
  hotFn = "hot_loop_spin";
  coldFn = "cold_block_wait";

  # Shorten collection and discovery for the exit test. A push gets one
  # collect interval, and the stopped target is retained for two.
  # see: nixos/mods/o11y/collector/alloy.nix
  collectIntervalS = 3;
  refreshIntervalMs = 500;
  ingestPassword = "machine-test-password-0123456789";
in
{
  name = "o11y-profiling-ebpf";

  globalTimeout = 300;

  nodes.machine =
    { lib, pkgs, ... }:
    let
      secret = name: text: pkgs.writeText name "${text}\n";

      ingestLib = import ./lib/o11y-ingest.nix { inherit pkgs; };
      tls = ingestLib.tlsCert "machine";

      # Test C symbolization after stdenv strips debug info and keeps .symtab.
      ebpfTarget = pkgs.stdenv.mkDerivation {
        name = unit;
        src = ./fixtures/ebpf-target.c;
        dontUnpack = true;
        buildPhase = ''
          $CC -O2 -pthread -o ${unit} $src
        '';
        installPhase = ''
          install -Dm755 ${unit} $out/bin/${unit}
        '';
        meta.mainProgram = unit;
      };

      workloadConfig = {
        ExecStart = lib.getExe ebpfTarget;
        # Exercise unit attribution outside system.slice.
        Slice = "workload.slice";
        DynamicUser = true;
        # Leave CPU for Alloy and Pyroscope.
        Nice = 10;
      };
    in
    {
      imports = [ ./lib/victoriametrics.nix ];

      # Leave two vCPUs for services while both workload threads spin.
      virtualisation.cores = 4;
      virtualisation.memorySize = 2048;
      # Match sauna's kernel and exercise BPF, perf, and ptrace restrictions.
      # see: nixos/sauna/default.nix
      boot.kernelPackages = pkgs.linuxPackages_latest;
      boot.kernel.sysctl = {
        "kernel.kptr_restrict" = 1;
        "kernel.perf_event_paranoid" = 2;
        "kernel.unprivileged_bpf_disabled" = 2;
        "kernel.yama.ptrace_scope" = 1;
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.phlip9-o11y = {
        server = {
          enable = true;
          retentionPeriod = "1d";
          grafana = {
            adminPasswordFile = secret "gf-admin-pwd" "gf-admin-testpwd";
            secretKeyFile = secret "gf-secret-key" "test-secret-key-0123456789";
            secretsManagerKeyFile = secret "gf-sm-key" "test-sm-key-0123456789";
          };
          profiling.enable = true;
          ingest = {
            enable = true;
            vhost = "machine";
            htpasswdFile = ingestLib.htpasswd { machine = ingestPassword; };
          };
        };
        collector = {
          enable = true;
          remote = {
            url = "https://machine/o11y";
            passwordFile = secret "o11y-ingest-password" ingestPassword;
          };
          profiling = {
            enable = true;
            collectInterval = "${toString collectIntervalS}s";
            refreshInterval = "${toString refreshIntervalMs}ms";
            testHooks = true;
          };
        };
      };

      services.grafana.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        virtualHosts.machine = {
          onlySSL = true;
          sslCertificate = "${tls}/cert.pem";
          sslCertificateKey = "${tls}/key.pem";
        };
      };
      security.pki.certificateFiles = [ "${tls}/cert.pem" ];

      services.vmagent.prometheusConfig.global.scrape_interval = "1s";

      systemd.services.${unit} = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = workloadConfig;
      };

      systemd.services.${exitedUnit}.serviceConfig = workloadConfig // {
        # Sample the exit workload quickly alongside the steady spinners.
        Nice = 0;
      };

      # Run two loops for enough short-lived PIDs under CI load. Each child
      # burns CPU and usually exits before Alloy's next discovery refresh.
      systemd.services.${forkUnit}.serviceConfig = workloadConfig // {
        ExecStart = pkgs.writeShellScript forkUnit ''
          spawn() {
            while :; do
              ${lib.getExe pkgs.bash} -c \
                'for ((idx = 0; idx < 500; idx++)); do :; done'
            done
          }
          spawn &
          spawn &
          wait
        '';
        Nice = 0;
      };
    };

  testScript = ''
    import datetime as dt
    import json
    import time

    from testlib import (
        CMD_TIMEOUT,
        CURL,
        UP_TIMEOUT,
        dump_evidence,
        wait_fast,
        wait_for_http,
    )
    from testlib.o11y import (
        PYRO_URL,
        metric_sum,
        metrics_scrape,
        pyro_fn_names,
        pyro_label_values,
        pyro_post as _pyro_post,
        wait_for_vm_labels,
    )

    ALLOY_URL = "http://127.0.0.1:12345"
    # Allow for BPF load, the first Alloy push, and Pyroscope indexing.
    PROFILE_TIMEOUT = dt.timedelta(seconds=90)
    # Bound polls for discovery and flush events even under host load.
    EVENT_TIMEOUT = dt.timedelta(seconds=30)

    CPU_TYPE = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
    OFFCPU_TYPE = "offcpu:offcpu:nanoseconds::"
    COLLECT_INTERVAL_MS = ${toString collectIntervalS} * 1000
    UNIT = "${unit}"
    TARGET_SEL = f'{{service_name="{UNIT}"}}'
    EXITED_UNIT = "${exitedUnit}"
    EXITED_SEL = f'{{service_name="{EXITED_UNIT}"}}'
    UNSPECIFIED = "ebpf/unspecified"
    UNSPECIFIED_SEL = f'{{service_name="{UNSPECIFIED}"}}'
    FORK_UNIT = "${forkUnit}"
    KERNEL_SEL = '{service_name="kernel"}'
    HOT_FN = "${hotFn}"
    COLD_FN = "${coldFn}"
    # Named frames identify workload samples, including mislabeled ones.
    # see: nixos/tests/fixtures/ebpf-target.c
    WORKLOAD_FNS = {HOT_FN, "hot_syscall_spin", COLD_FN}
    # Kernel symbols expected from the workload's /dev/zero reads.
    KERNEL_FNS = {
        "do_syscall_64",
        "entry_SYSCALL_64_after_hwframe",
        "entry_SYSCALL_64",
        "ksys_read",
        "vfs_read",
        "read_zero",
        "__x64_sys_read",
    }
    ALLOY_CAPS = {
        "BPF", "PERFMON", "SYS_PTRACE", "CHECKPOINT_RESTORE",
        "DAC_READ_SEARCH", "SYSLOG",
    }
    # Capability names indexed by bit number in /proc/<pid>/status.
    CAP_NAMES = [
        "CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID",
        "KILL", "SETGID", "SETUID", "SETPCAP", "LINUX_IMMUTABLE",
        "NET_BIND_SERVICE", "NET_BROADCAST", "NET_ADMIN", "NET_RAW",
        "IPC_LOCK", "IPC_OWNER", "SYS_MODULE", "SYS_RAWIO", "SYS_CHROOT",
        "SYS_PTRACE", "SYS_PACCT", "SYS_ADMIN", "SYS_BOOT", "SYS_NICE",
        "SYS_RESOURCE", "SYS_TIME", "SYS_TTY_CONFIG", "MKNOD", "LEASE",
        "AUDIT_WRITE", "AUDIT_CONTROL", "SETFCAP", "MAC_OVERRIDE",
        "MAC_ADMIN", "SYSLOG", "WAKE_ALARM", "BLOCK_SUSPEND", "AUDIT_READ",
        "PERFMON", "BPF", "CHECKPOINT_RESTORE",
    ]

    def decode_caps(hexmask: str) -> set[str]:
        mask = int(hexmask, 16)
        return {name for idx, name in enumerate(CAP_NAMES) if mask >> idx & 1}

    def proc_status(unit: str) -> dict[str, str]:
        pid = machine.succeed(
            f"systemctl show {unit} -p MainPID --value", timeout=CMD_TIMEOUT
        ).strip()
        out = machine.succeed(f"cat /proc/{pid}/status", timeout=CMD_TIMEOUT)
        status = {}
        for line in out.splitlines():
            key, _, val = line.partition(":")
            status[key] = val.strip()
        return status

    def unit_cpu_ns(unit: str) -> int:
        return int(machine.succeed(
            f"systemctl show {unit} -p CPUUsageNSec --value",
            timeout=CMD_TIMEOUT,
        ))

    # Count BPF links even if unrelated FDs close during the find scan.
    def bpf_links(unit: str) -> int:
        pid = machine.succeed(
            f"systemctl show {unit} -p MainPID --value", timeout=CMD_TIMEOUT
        ).strip()
        out = machine.succeed(
            f"find /proc/{pid}/fd -lname 'anon_inode:bpf_link' || true",
            timeout=CMD_TIMEOUT,
        )
        return len(out.split())

    # Use guest time for Pyroscope's profile query bounds.
    def vm_now_ms() -> int:
        return int(machine.succeed("date +%s%3N", timeout=CMD_TIMEOUT))

    def pyro_post(
        method: str, body: dict, timeout: dt.timedelta = EVENT_TIMEOUT
    ) -> dict:
        return _pyro_post(machine, method, body, retry_timeout=timeout)

    # Read symbols from the merged flame graph in the requested time window.
    def fn_names(
        ptype: str,
        selector: str,
        start_ms: int | None = None,
        end_ms: int | None = None,
        timeout: dt.timedelta = EVENT_TIMEOUT,
    ) -> set[str]:
        return pyro_fn_names(
            machine,
            ptype,
            selector,
            start_ms=start_ms,
            end_ms=end_ms,
            retry_timeout=timeout,
        )

    def label_values(label: str, selector: str | None = None) -> list[str]:
        return pyro_label_values(
            machine, label, selector=selector, retry_timeout=EVENT_TIMEOUT
        )

    # Wait for matching frames and report the last observed names on failure.
    def wait_for_profile(
        ptype: str, selector: str, check, what: str,
        start_ms: int | None = None,
        end_ms: int | None = None,
    ):
        seen = set()
        deadline = time.monotonic() + PROFILE_TIMEOUT.total_seconds()

        def poll() -> bool:
            nonlocal seen
            # Share the poll deadline with query retries.
            left = dt.timedelta(seconds=max(0.0, deadline - time.monotonic()))
            seen = fn_names(ptype, selector, start_ms, end_ms, left)
            return check(seen)

        try:
            wait_fast(poll, what, PROFILE_TIMEOUT)
        except Exception:
            print(f"{what}: last names seen: {sorted(seen)[:60]}")
            raise
        return seen

    def alloy_scrape() -> list[str]:
        return metrics_scrape(machine, ALLOY_URL)

    # --- Alloy test hooks --- #

    # Call the profiler hooks enabled by collector.profiling.testHooks.
    # see: nixos/pkgs/grafana-alloy/ebpf-test-hooks.patch
    def ebpf_hook(path: str, method: str = "GET") -> dict:
        out = machine.succeed(
            f"{CURL} -f -X {method} "
            f"'{ALLOY_URL}/api/v0/component/pyroscope.ebpf.host/{path}'",
            timeout=CMD_TIMEOUT,
        )
        return json.loads(out)

    # Return after pushes finish, with an isolated query window for the batch.
    # hold pauses periodic flushes until a manual flush releases them.
    def ebpf_flush(hold: bool) -> dict:
        resp = ebpf_hook(f"flush?hold={str(hold).lower()}", "POST")
        assert resp["failed_pushes"] == 0, resp
        return resp

    # Select profiles by service and type within a flush result.
    def flushed(flush: dict, service: str, name: str) -> list[dict]:
        return [
            prof for prof in flush["profiles"]
            if prof["labels"].get("service_name") == service
            and prof["labels"].get("__name__") == name
        ]

    # Read the profiler's applied target for a PID, live or retained after exit.
    def applied_target(pid: int) -> tuple[dict | None, dict | None]:
        resp = ebpf_hook("targets")

        def find(kind: str) -> dict | None:
            return next(
                (target for target in resp[kind] if target["pid"] == pid),
                None,
            )

        return find("live"), find("exited")

    def pending_cpu(pid: int) -> int:
        return sum(
            entry["samples"] for entry in ebpf_hook("pending")["pending"]
            if entry["pid"] == pid and entry["type"] == "process_cpu"
        )

    # Estimate the next flush's series from pending samples and applied labels.
    def pending_series() -> set[tuple]:
        targets = ebpf_hook("targets")
        labels_by_pid = {
            target["pid"]: target["labels"]
            for target in targets["exited"] + targets["live"]
        }
        series = set()
        for entry in ebpf_hook("pending")["pending"]:
            labels = labels_by_pid.get(
                entry["pid"], {"service_name": UNSPECIFIED}
            )
            series.add(
                (labels["service_name"], labels.get("exe"), entry["type"])
            )
        return series

    # Include the forker's undiscovered PIDs under the fallback service label.
    def fanout_metric(scrape: list[str], name: str) -> float:
        return sum(
            metric_sum(scrape, name, f'service_name="{service}"')
            for service in [UNSPECIFIED, FORK_UNIT]
        )

    # Read the last PID allocated by the guest kernel.
    def last_pid() -> int:
        out = machine.succeed("cat /proc/loadavg", timeout=CMD_TIMEOUT)
        return int(out.split()[4])

    # Estimate PID churn across wraparound.
    def pids_since(pid0: int) -> int:
        pid_max = int(machine.succeed(
            "cat /proc/sys/kernel/pid_max", timeout=CMD_TIMEOUT
        ))
        return (last_pid() - pid0) % pid_max

    EVIDENCE = [(
        machine,
        [
            "systemctl status alloy pyroscope ${unit} --no-pager | head -n 60",
            "journalctl --no-pager -o cat -u alloy | tail -n 100",
            "journalctl --no-pager -o cat -u pyroscope | tail -n 50",
            f"{CURL} {ALLOY_URL}/metrics "
            "| grep -E '^(pyroscope_(ebpf|write)|alloy_component_controller)'",
            f"{CURL} {PYRO_URL}/metrics "
            "| grep -E '^pyroscope_(distributor_push_batch_series|request_"
            "duration_seconds_count.*push)'",
            f"{CURL} {ALLOY_URL}/api/v0/web/components "
            "| jq -c '.[] | {id: .localID, health: .health}'",
            f"{CURL} {PYRO_URL}/ready",
            "tail -n 20 /var/log/nginx/access.log",
            "journalctl --no-pager -o cat -u nginx | tail -n 20",
        ],
    )]

    machine.start()
    try:
        # --- Startup and profile delivery --- #

        with subtest("Pyroscope, Alloy, and workload readiness"):
            machine.wait_for_unit(
                "pyroscope.service", timeout=dt.timedelta(seconds=90)
            )
            wait_for_http(machine, f"{PYRO_URL}/ready", timeout=UP_TIMEOUT)
            # Surface query failures before checking for profile data.
            try:
                pyro_post("NoSuchMethod", {}, timeout=dt.timedelta(0))
            except Exception:
                pass
            else:
                raise Exception("pyro_post: a failed request passed")
            machine.wait_for_unit("alloy.service", timeout=UP_TIMEOUT)
            wait_for_http(machine, f"{ALLOY_URL}/-/ready", timeout=UP_TIMEOUT)
            machine.wait_for_unit(f"{UNIT}.service", timeout=UP_TIMEOUT)

        with subtest("Alloy uses its service UID and expected capabilities"):
            status = proc_status("alloy")
            alloy_uid = machine.succeed(
                "id -u alloy", timeout=CMD_TIMEOUT
            ).strip()
            caps = decode_caps(status["CapEff"])
            print(f"alloy: Uid {status['Uid']}, CapEff {sorted(caps)}")
            # Check real, effective, saved, and filesystem UIDs.
            assert status["Uid"].split() == [alloy_uid] * 4, status
            assert alloy_uid != "0", alloy_uid
            assert caps == ALLOY_CAPS, caps
            assert decode_caps(status["CapAmb"]) == ALLOY_CAPS, status

        with subtest("CPU profile includes named user and kernel frames"):
            names = wait_for_profile(
                CPU_TYPE, TARGET_SEL,
                lambda names: HOT_FN in names and bool(KERNEL_FNS & names),
                "cpu",
            )
            print(f"kernel frames: {sorted(KERNEL_FNS & names)}")
            cpu_t0 = time.monotonic()
            cpu_ns0 = unit_cpu_ns("alloy")

        with subtest("Alloy authenticates over HTTP/2 at the ingest prefix"):
            machine.succeed(
                "grep -qE ' machine \\[.*\\] \"POST "
                "/o11y/profiles/push.v1.PusherService/Push HTTP/2.0\" 200 ' "
                "/var/log/nginx/access.log",
                "test -s /run/credentials/alloy.service/o11y-remote-password",
                timeout=CMD_TIMEOUT,
            )

        with subtest("Off-CPU profile includes the blocking function"):
            wait_for_profile(
                OFFCPU_TYPE, TARGET_SEL,
                lambda names: COLD_FN in names,
                "offcpu",
            )

        # --- Probe lifetime, exit attribution, and batching --- #

        with subtest("Force garbage collection in Alloy"):
            # GC used to close the unreachable off-CPU probe's BPF links.
            # see: nixos/pkgs/grafana-alloy/ebpf-keep-probes-alive.patch
            links0 = bpf_links("alloy")
            print(f"alloy BPF links before GC: {links0}")
            assert links0 > 0, links0
            machine.succeed(
                f"{CURL} -f -o /dev/null '{ALLOY_URL}/debug/pprof/heap?gc=1'",
                timeout=CMD_TIMEOUT,
            )
            # Alloy timestamps profiles at flush. Skip the batch that spans GC.
            fresh_ms = vm_now_ms() + COLLECT_INTERVAL_MS

        with subtest("Last samples retain the exited process's unit label"):
            # Alloy resolves labels at flush. Losing the exited target sends
            # its last samples to ebpf/unspecified.
            # see: nixos/pkgs/grafana-alloy/ebpf-keep-exited-targets.patch
            min_samples = 5
            machine.succeed(
                f"systemctl start {EXITED_UNIT}", timeout=CMD_TIMEOUT
            )
            pid = int(machine.succeed(
                f"systemctl show {EXITED_UNIT} -p MainPID --value",
                timeout=CMD_TIMEOUT,
            ))
            assert pid != 0, pid

            # Wait for the profiler to apply the discovered unit label.
            def live_as_unit() -> bool:
                live, _ = applied_target(pid)
                return (
                    live is not None
                    and live["labels"].get("service_name") == EXITED_UNIT
                )

            wait_fast(live_as_unit, "Alloy applies the pid", EVENT_TIMEOUT)

            # Clear the buffer and use manual flushes for both snapshots.
            ebpf_flush(hold=True)
            wait_fast(
                lambda: pending_cpu(pid) >= min_samples,
                "samples of the pid",
                EVENT_TIMEOUT,
            )
            f0 = ebpf_flush(hold=True)
            assert flushed(f0, EXITED_UNIT, "process_cpu"), f0
            wait_for_profile(
                CPU_TYPE, EXITED_SEL,
                lambda names: bool(WORKLOAD_FNS & names),
                "F0: the unit's cpu profile",
                start_ms=f0["start_ms"], end_ms=f0["end_ms"],
            )

            # Leave samples pending across exit and applied target removal.
            wait_fast(
                lambda: pending_cpu(pid) >= min_samples,
                "samples of the pid since F0",
                EVENT_TIMEOUT,
            )
            machine.succeed(
                f"systemctl stop {EXITED_UNIT}", timeout=CMD_TIMEOUT
            )
            wait_fast(
                lambda: applied_target(pid)[0] is None,
                "Alloy applies the pid's removal",
                EVENT_TIMEOUT,
            )
            _, exited = applied_target(pid)
            pending = pending_cpu(pid)
            print(f"exited pid {pid}: {exited}, {pending} samples pending")
            assert exited is not None, "removed pid's target not retained"
            assert exited["labels"].get("service_name") == EXITED_UNIT, exited

            f1 = ebpf_flush(hold=False)
            assert flushed(f1, EXITED_UNIT, "process_cpu"), f1
            wait_for_profile(
                CPU_TYPE, EXITED_SEL,
                lambda names: bool(WORKLOAD_FNS & names),
                "F1: the exited unit's cpu profile",
                start_ms=f1["start_ms"], end_ms=f1["end_ms"],
            )

            # One fallback profile per type per flush makes readback complete
            # as soon as that profile is visible in the flush window.
            for flush in [f0, f1]:
                for ptype, name in [
                    (CPU_TYPE, "process_cpu"), (OFFCPU_TYPE, "offcpu"),
                ]:
                    profs = flushed(flush, UNSPECIFIED, name)
                    if not profs:
                        continue
                    assert len(profs) == 1, profs
                    names = wait_for_profile(
                        ptype, UNSPECIFIED_SEL, bool,
                        f"unspecified {name} profile",
                        start_ms=flush["start_ms"], end_ms=flush["end_ms"],
                    )
                    assert not WORKLOAD_FNS & names, (name, names)

        with subtest("One push per flush delivers every profile series"):
            # Hold periodic flushes to isolate one batch in the counters.
            # see: nixos/pkgs/grafana-alloy/pyroscope-batch-push.patch
            min_series = 8
            ebpf_flush(hold=True)
            wait_fast(
                lambda: len(pending_series()) >= min_series,
                f"samples of {min_series} series",
                EVENT_TIMEOUT,
            )
            pyro0, alloy0 = metrics_scrape(machine, PYRO_URL), alloy_scrape()
            flush_t0 = time.monotonic()
            flush = ebpf_flush(hold=True)
            flush_s = time.monotonic() - flush_t0
            pyro1, alloy1 = metrics_scrape(machine, PYRO_URL), alloy_scrape()

            def delta(
                scrape0: list[str], scrape1: list[str], name: str,
                match: str = "",
            ) -> float:
                return (
                    metric_sum(scrape1, name, match)
                    - metric_sum(scrape0, name, match)
                )

            requests = delta(
                pyro0, pyro1, "pyroscope_distributor_push_batch_series_count"
            )
            series = delta(
                pyro0, pyro1, "pyroscope_distributor_push_batch_series_sum"
            )
            attempts, push_s = (
                delta(alloy0, alloy1, f"pyroscope_write_latency_{stat}",
                      'type="push_downstream"')
                for stat in ["count", "sum"]
            )
            sent_bytes = delta(
                alloy0, alloy1, "pyroscope_write_sent_bytes_total"
            )
            profiles = flush["profiles"]
            print(
                f"batch: {len(profiles)} profiles -> {requests:.0f} "
                f"requests, {series:.0f} series, {sent_bytes:.0f} B; push "
                f"{push_s:.3f}s, flush {flush_s:.3f}s"
            )
            assert len(profiles) >= min_series, profiles
            assert requests == 1, requests
            assert attempts == 1, attempts
            assert series == len(profiles), (series, len(profiles))

            ptypes = {"process_cpu": CPU_TYPE, "offcpu": OFFCPU_TYPE}
            keys = {
                (
                    prof["labels"]["__name__"],
                    prof["labels"]["service_name"],
                    prof["labels"].get("exe", ""),
                )
                for prof in profiles
            }
            for name, service, exe in sorted(keys):
                selector = (
                    f"{{service_name={json.dumps(service)}, "
                    f"exe={json.dumps(exe)}}}"
                )
                wait_for_profile(
                    ptypes[name], selector, bool, f"{name} {selector}",
                    start_ms=flush["start_ms"], end_ms=flush["end_ms"],
                )
            ebpf_flush(hold=False)

        with subtest("Off-CPU samples and BPF links survive GC"):
            wait_for_profile(
                OFFCPU_TYPE, TARGET_SEL,
                lambda names: COLD_FN in names,
                "offcpu after GC",
                start_ms=fresh_ms,
            )
            links1 = bpf_links("alloy")
            print(f"alloy BPF links after GC: {links1}")
            assert links1 == links0, (links0, links1)

        with subtest("Short-lived PIDs aggregate into profiles by label set"):
            # Per-PID pushes reached 600-850 per 15s on sauna and missed the
            # push deadline under load. Count PIDs to keep workload size
            # stable across different VM speeds.
            # see: nixos/pkgs/grafana-alloy/ebpf-per-pid-profile.patch
            fanout_pids = 300
            start_ms = vm_now_ms()
            pids0 = last_pid()
            scrape0 = alloy_scrape()
            machine.succeed(f"systemctl start {FORK_UNIT}", timeout=CMD_TIMEOUT)
            wait_fast(
                lambda: pids_since(pids0) >= fanout_pids,
                f"{fanout_pids} new pids",
                PROFILE_TIMEOUT,
            )
            stop_ms = int(machine.succeed(
                f"systemctl stop {FORK_UNIT} && date +%s%3N",
                timeout=CMD_TIMEOUT,
            ))
            pids = pids_since(pids0)
            # Allow two flushes after stop to drain buffered samples.
            wait_fast(
                lambda: bool(
                    fn_names(CPU_TYPE, "{}", stop_ms + COLLECT_INTERVAL_MS)
                ),
                "the 2nd flush after the stop",
                PROFILE_TIMEOUT,
            )
            scrape1 = alloy_scrape()
            end_ms = vm_now_ms()
            pprofs = fanout_metric(
                scrape1, "pyroscope_ebpf_pprofs_total"
            ) - fanout_metric(scrape0, "pyroscope_ebpf_pprofs_total")
            samples = fanout_metric(
                scrape1, "pyroscope_ebpf_pprof_samples_total"
            ) - fanout_metric(scrape0, "pyroscope_ebpf_pprof_samples_total")
            # Allow partial flushes and counter updates across scrape bounds.
            flushes = (end_ms - start_ms) / COLLECT_INTERVAL_MS + 2
            print(
                f"fan-out: {pids} new pids, {pprofs:.0f} pprofs, "
                f"{samples:.0f} samples (compacted), <= {flushes:.1f} "
                "flushes"
            )
            assert pids >= fanout_pids, pids
            assert samples > 0, samples
            # Allow CPU and off-CPU for each of the two service labels.
            assert pprofs <= 4 * flushes, (pprofs, flushes)
            for name in [
                "pyroscope_write_dropped_profiles_total",
                "pyroscope_ebpf_pprofs_dropped_total",
            ]:
                assert metric_sum(scrape1, name) == 0, name

        # --- Frame symbols and series labels --- #

        with subtest("Kernel thread profiles use the kernel service label"):
            # Trigger kworker samples with page-cache writeback.
            machine.succeed(
                "dd if=/dev/zero of=/var/tmp/writeback bs=1M count=128 "
                "status=none && sync && rm /var/tmp/writeback",
                timeout=CMD_TIMEOUT,
            )
            wait_for_profile(
                CPU_TYPE, KERNEL_SEL,
                lambda names: "kthread" in names,
                "kernel cpu",
            )
            exes = label_values("exe", KERNEL_SEL)
            assert exes == [], exes

        with subtest("VictoriaMetrics CPU profile includes Go frames"):
            # The binary lacks .symtab, so symbolization needs .gopclntab.
            wait_for_profile(
                CPU_TYPE,
                '{service_name="victoriametrics"}',
                lambda names: any(
                    name.startswith(("runtime.", "github.com/VictoriaMetrics/"))
                    for name in names
                ),
                "victoriametrics cpu",
            )

        with subtest("Workload profiles expose service, exe, and host labels"):
            resp = pyro_post("LabelNames", {"matchers": [TARGET_SEL]})
            names = resp.get("names", [])
            print(f"label names: {names}")
            assert {"service_name", "exe", "host"} <= set(names), names
            leaked = [
                name for name in names
                if name.startswith("__meta_") or "pid" in name
            ]
            assert not leaked, names
            assert label_values("exe", TARGET_SEL) == [UNIT], names
            assert label_values("host", TARGET_SEL) == ["machine"], names
            services = label_values("service_name")
            print(f"service_name values: {services}")
            assert "alloy" in services, services

        # --- Health metrics --- #

        with subtest("Alloy reports delivery and healthy components"):
            scrape = alloy_scrape()
            sent = metric_sum(scrape, "pyroscope_write_sent_profiles_total")
            assert sent > 0, sent
            for name in [
                "pyroscope_write_dropped_profiles_total",
                "pyroscope_ebpf_pprofs_dropped_total",
                "pyroscope_ebpf_profiling_sessions_failing_total",
            ]:
                assert metric_sum(scrape, name) == 0, name
            # Require reported components before checking for unhealthy ones.
            healthy = metric_sum(
                scrape,
                "alloy_component_controller_running_components",
                'health_type="healthy"',
            )
            assert healthy >= 4, healthy
            for health in ["unhealthy", "exited", "unknown"]:
                assert metric_sum(
                    scrape,
                    "alloy_component_controller_running_components",
                    f'health_type="{health}"',
                ) == 0, health

        with subtest("VictoriaMetrics scrapes Alloy and Pyroscope disk usage"):
            wait_for_vm_labels(machine, 'up{job="alloy"} == 1')
            # Collect disk usage on demand to avoid waiting for the timer.
            machine.succeed("systemctl start pyroscope-du", timeout=CMD_TIMEOUT)
            wait_for_vm_labels(machine, "pyroscope_data_bytes > 0")

        # Log resource use for tuning. Measure CPU after the first profile.
        cpu_ns1 = unit_cpu_ns("alloy")
        cpu_pct = (cpu_ns1 - cpu_ns0) / 1e9 / (time.monotonic() - cpu_t0) * 100
        print(f"alloy: {cpu_pct:.1f}% of a core")
        for svc in ["alloy", "pyroscope"]:
            status = proc_status(svc)
            print(f"{svc}: VmRSS {status['VmRSS']}, VmHWM {status['VmHWM']}")
        print(machine.succeed(
            "systemctl show alloy pyroscope -p Id -p CPUUsageNSec "
            "-p MemoryCurrent -p MemoryPeak; "
            "journalctl -o cat -u alloy "
            "| grep -ciE 'level=(warn|error)' || true",
            timeout=CMD_TIMEOUT,
        ))
    except Exception:
        dump_evidence(EVIDENCE)
        raise
  '';
}
