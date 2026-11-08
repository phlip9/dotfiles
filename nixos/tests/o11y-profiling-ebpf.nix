# NixOS VM test: whole-host eBPF profiling, end to end.
#
# One VM w/ the phlip9-o11y profiling stack: Pyroscope + the Alloy
# `pyroscope.ebpf` collector (non-root `alloy` user, ambient caps, hardened
# unit). The workload, `ebpf-target.service`, is a tiny C program w/ named
# hot/cold fns that runs as another (dynamic) user. Needs a VM, not a
# container: eBPF + perf events need the (guest) kernel.
#
# Verifies:
# - Alloy runs as uid `alloy` w/ exactly its ambient caps
# - a CPU profile for `service_name="ebpf-target"` w/ the user hot fn name
#   (NOT just any profile: missing caps fail silently as `[unknown]`
#   frames) + a symbolized kernel frame
# - Go frames for VictoriaMetrics, a go1.27 binary w/o `.symtab`
# - series labels: `exe` + `host`, no pid or `__meta_*` leaks
# - an `offcpu` profile w/ the blocking fn
# - Alloy's `/metrics`: pushes sent, none dropped, components healthy;
#   VictoriaMetrics scrapes it
#
# Mirrors sauna: latest kernel + its BPF/perf/ptrace sysctls.
let
  # Workload unit
  unit = "ebpf-target";
  # On-CPU fn, user frames only
  hotFn = "hot_loop_spin";
  # Blocks in nanosleep(2): off-CPU
  coldFn = "cold_block_wait";
in
{
  name = "o11y-profiling-ebpf";

  globalTimeout = 300;

  nodes.machine =
    { lib, pkgs, ... }:
    let
      secret = name: text: pkgs.writeText name "${text}\n";

      # stdenv build, so fixup strips debug info (`strip -S`) but keeps
      # `.symtab`, like most nixpkgs C/C++ binaries.
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
    in
    {
      virtualisation.cores = 2;
      virtualisation.memorySize = 2048;
      # = sauna
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
        enable = true;
        retentionPeriod = "1d";
        grafana = {
          adminPasswordFile = secret "gf-admin-pwd" "gf-admin-testpwd";
          secretKeyFile = secret "gf-secret-key" "test-secret-key-0123456789";
          secretsManagerKeyFile = secret "gf-sm-key" "test-sm-key-0123456789";
        };
        profiling = {
          enable = true;
          # Faster first profile. Everything else: prod defaults.
          collector.collectInterval = "5s";
        };
      };

      # Unused here: Grafana (covered by o11y-profiling), node metrics, ssh
      services.grafana.enable = lib.mkForce false;
      services.prometheus.exporters.node.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;

      services.victoriametrics.prometheusConfig.global.scrape_interval = "1s";
      # Queries hide samples younger than `-search.latencyOffset` (30s).
      services.victoriametrics.extraOptions = [
        "-search.latencyOffset=0s"
        # Grafana's scrape job: one error per second
        "-promscrape.suppressScrapeErrors"
      ];

      systemd.services.${unit} = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = lib.getExe ebpfTarget;
          DynamicUser = true;
          # Leave CPU for Alloy + Pyroscope on 2 vCPUs
          Nice = 10;
        };
      };
    };

  testScript = ''
    import datetime as dt
    import json
    import shlex
    import time

    PYRO_URL = "http://127.0.0.1:4040"
    ALLOY_URL = "http://127.0.0.1:12345"
    VM_URL = "http://127.0.0.1:8428"
    # Bound every request, so a hung server fails its step, not the test's
    # globalTimeout, and `dump_evidence` still runs.
    CURL = "curl -sS --connect-timeout 2 --max-time 10"
    # Upper bound for one command, incl. its curl
    CMD_TIMEOUT = dt.timedelta(seconds=15)
    # Upper bound for profiles to show up. Usually ~15-25s after Alloy
    # starts: BPF load + first collect interval + Pyroscope flush.
    PROFILE_TIMEOUT = dt.timedelta(seconds=90)
    # Upper bound for a service to start + turn ready
    UP_TIMEOUT = dt.timedelta(seconds=60)

    CPU_TYPE = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
    UNIT = "${unit}"
    TARGET_SEL = f'{{service_name="{UNIT}"}}'
    HOT_FN = "${hotFn}"
    COLD_FN = "${coldFn}"
    # Any of these under `hot_syscall_spin` = symbolized kernel frames
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
    # Linux cap numbers -> names, to decode /proc/<pid>/status
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

    # Query window: since boot, until well after now
    def window() -> dict:
        now_ms = int(machine.succeed("date +%s%3N", timeout=CMD_TIMEOUT))
        return {"start": now_ms - 3_600_000, "end": now_ms + 60_000}

    # POST to Pyroscope's Connect query API. {} on error, so polls retry.
    def pyro_post(method: str, body: dict) -> dict:
        data = shlex.quote(json.dumps({**body, **window()}))
        status, out = machine.execute(
            f"{CURL} --fail-with-body -H 'Content-Type: application/json' "
            f"--data-binary {data} "
            f"{PYRO_URL}/querier.v1.QuerierService/{method}",
            timeout=CMD_TIMEOUT,
        )
        if status != 0:
            print(f"Pyroscope {method}: {out}")
            return {}
        return json.loads(out)

    # Function names in the merged flame graph of `ptype` for `selector`.
    def fn_names(ptype: str, selector: str) -> set[str]:
        resp = pyro_post("SelectMergeStacktraces", {
            "profileTypeID": ptype,
            "labelSelector": selector,
        })
        return set(resp.get("flamegraph", {}).get("names", []))

    def label_values(label: str, selector: str | None = None) -> list[str]:
        matchers = [selector] if selector else []
        resp = pyro_post("LabelValues", {"name": label, "matchers": matchers})
        return resp.get("names", [])

    # Poll until `check(names)` holds for the profile. Pyroscope has no push
    # notification. Returns the last names seen.
    def wait_for_profile(ptype: str, selector: str, check, what: str):
        seen = set()

        def poll(last_try: bool) -> bool:
            nonlocal seen
            seen = fn_names(ptype, selector)
            if last_try:
                print(f"{what}: last names seen: {sorted(seen)[:60]}")
            return check(seen)

        retry(poll, timeout=PROFILE_TIMEOUT)
        return seen

    # Alloy's Prometheus metrics, summed per metric name + label filter.
    def alloy_metric(name: str, match: str = "") -> float:
        out = machine.succeed(
            f"{CURL} -f {ALLOY_URL}/metrics", timeout=CMD_TIMEOUT
        )
        total = 0.0
        for line in out.splitlines():
            if line.startswith(name + "{") or line.startswith(name + " "):
                if match in line:
                    total += float(line.rsplit(" ", 1)[1])
        return total

    def dump_evidence() -> None:
        for cmd in [
            "systemctl status alloy pyroscope ${unit} --no-pager | head -n 60",
            "journalctl --no-pager -o cat -u alloy | tail -n 100",
            "journalctl --no-pager -o cat -u pyroscope | tail -n 50",
            f"{CURL} {ALLOY_URL}/metrics "
            "| grep -E '^(pyroscope_(ebpf|write)|alloy_component_controller)'",
            f"{CURL} {ALLOY_URL}/api/v0/web/components "
            "| jq -c '.[] | {id: .localID, health: .health}'",
            f"{CURL} {PYRO_URL}/ready",
        ]:
            _, out = machine.execute(cmd, timeout=CMD_TIMEOUT)
            print(f"$ {cmd}\n{out}")

    machine.start()
    try:
        with subtest("Pyroscope + Alloy + workload up"):
            machine.wait_for_unit(
                "pyroscope.service", timeout=dt.timedelta(seconds=90)
            )
            machine.wait_until_succeeds(
                f"{CURL} -f {PYRO_URL}/ready", timeout=UP_TIMEOUT
            )
            machine.wait_for_unit("alloy.service", timeout=UP_TIMEOUT)
            machine.wait_until_succeeds(
                f"{CURL} -f {ALLOY_URL}/-/ready", timeout=UP_TIMEOUT
            )
            machine.wait_for_unit(f"{UNIT}.service", timeout=UP_TIMEOUT)

        with subtest("Alloy runs as uid alloy w/ exactly its caps"):
            status = proc_status("alloy")
            alloy_uid = machine.succeed(
                "id -u alloy", timeout=CMD_TIMEOUT
            ).strip()
            caps = decode_caps(status["CapEff"])
            print(f"alloy: Uid {status['Uid']}, CapEff {sorted(caps)}")
            # real, effective, saved, fs
            assert status["Uid"].split() == [alloy_uid] * 4, status
            assert alloy_uid != "0", alloy_uid
            assert caps == ALLOY_CAPS, caps
            assert decode_caps(status["CapAmb"]) == ALLOY_CAPS, status

        with subtest("CPU profile: user hot fn + kernel frames"):
            names = wait_for_profile(
                CPU_TYPE, TARGET_SEL,
                lambda names: HOT_FN in names and bool(KERNEL_FNS & names),
                "cpu",
            )
            print(f"kernel frames: {sorted(KERNEL_FNS & names)}")
            cpu_t0 = time.monotonic()
            cpu_ns0 = int(machine.succeed(
                "systemctl show alloy -p CPUUsageNSec --value",
                timeout=CMD_TIMEOUT,
            ))

        # VictoriaMetrics is a go1.27 binary w/o `.symtab`, only
        # `.gopclntab`. Alloy 1.21 rejects go1.27 pclntabs.
        with subtest("CPU profile: Go frames"):
            wait_for_profile(
                CPU_TYPE,
                '{service_name="victoriametrics"}',
                lambda names: any(
                    name.startswith(("runtime.", "github.com/VictoriaMetrics/"))
                    for name in names
                ),
                "victoriametrics cpu",
            )

        with subtest("series labels: unit, exe, host; no pid, no __meta_*"):
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

        with subtest("off-CPU profile: blocking fn"):
            wait_for_profile(
                "offcpu:offcpu:nanoseconds::", TARGET_SEL,
                lambda names: COLD_FN in names,
                "offcpu",
            )

        with subtest("Alloy metrics: pushes sent, none dropped, healthy"):
            sent = alloy_metric("pyroscope_write_sent_profiles_total")
            assert sent > 0, sent
            for name in [
                "pyroscope_write_dropped_profiles_total",
                "pyroscope_ebpf_pprofs_dropped_total",
                "pyroscope_ebpf_profiling_sessions_failing_total",
            ]:
                assert alloy_metric(name) == 0, name
            # Prove the series exists before trusting the == 0 below
            healthy = alloy_metric(
                "alloy_component_controller_running_components",
                'health_type="healthy"',
            )
            assert healthy >= 4, healthy
            for health in ["unhealthy", "exited", "unknown"]:
                assert alloy_metric(
                    "alloy_component_controller_running_components",
                    f'health_type="{health}"',
                ) == 0, health

        with subtest("VictoriaMetrics scrapes Alloy"):
            query = shlex.quote('up{job="alloy"}')
            machine.wait_until_succeeds(
                f"{CURL} -f {VM_URL}/api/v1/query "
                f"--data-urlencode query={query} "
                "| jq -e '.data.result[0].value[1] == \"1\"'",
                timeout=dt.timedelta(seconds=30),
            )

        # Not an assertion: resource numbers for tuning. CPU over the
        # subtests above, after the first profile (startup excluded).
        cpu_ns1 = int(machine.succeed(
            "systemctl show alloy -p CPUUsageNSec --value", timeout=CMD_TIMEOUT
        ))
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
        dump_evidence()
        raise
  '';
}
