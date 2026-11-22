# o11y collector: whole-host eBPF profiler (Alloy `pyroscope.ebpf`).
#
#   Alloy (on/off-CPU eBPF) --push--> Pyroscope (local or `collector.remote`)
#
# Samples + symbolizes all host processes (labeled by systemd unit; kernel
# threads as `kernel`). Runs as non-root `alloy` user w/ ambient caps;
# self-metrics scraped as job `alloy`.
#
# See: ../server/pyroscope.nix
# See: doc/o11y/README.md
{
  config,
  lib,
  phlipPkgsNixos,
  pkgs,
  ...
}:

let
  cfg = config.services.phlip9-o11y;
  cfgC = cfg.collector;
  cfgP = cfgC.profiling;

  cfgPyroSrv = config.services.pyroscope.settings.server;
  cfgAlloy = config.services.alloy;

  inherit (import ./lib.nix { inherit config; }) hostTargets ingest;

  cfgRemote = cfgC.remote;
  isLocal = cfgRemote == null;

  writeLabel = if isLocal then "local" else "remote";
  writeUrl =
    if isLocal then
      "http://${pyroscopeAddr}"
    else
      "${cfgRemote.url}${ingest.profilesPath}";

  passwordCredential = "o11y-remote-password";
  passwordPath = alloyLit "/${passwordCredential}";

  # Alloy string/number literals follow JSON escaping.
  alloyLit = builtins.toJSON;

  # Fixed-uid normal users, for naming user-<uid>.slice.
  namedUsers = lib.filter (user: user.isNormalUser && user.uid != null) (
    lib.attrValues config.users.users
  );

  # Anchored RE2 matching any slice (ex: workload.slice). Captures `<unit>` or
  # `<template>@` to collapse template instances.
  systemUnitRegex = lib.concatStrings [
    "0::/"
    "(?:[^/]+\\.slice/)+"
    "([^/@]+@?)[^/]*"
    "\\.service(?:/.*)?"
  ];

  alloyConfig = ''
    // Whole-host eBPF profiling (nixos/mods/o11y/collector/alloy.nix).
    // process -> relabel -> pyroscope.ebpf -> pyroscope.write

    // Userspace processes (full /proc scan; skips exe-less kernel threads).
    discovery.process "all" {
      refresh_interval = ${alloyLit cfgP.refreshInterval}

      discover_config {
        cgroup_path = true
        exe         = true
        // Unused; skip /proc reads.
        commandline  = false
        container_id = false
        cwd          = false
        uid          = false
        username     = false
      }
    }

    // Map cgroup -> service_name, exe -> basename (non-`__` labels exported).
    discovery.relabel "units" {
      targets = discovery.process.all.targets

      // Unit or `<template>@` (collapses instances to bound cardinality).
      // `user@<uid>.service` overridden below.
      rule {
        source_labels = ["__meta_process_cgroup_path"]
        regex         = ${alloyLit systemUnitRegex}
        target_label  = "service_name"
      }

      // User sessions + managers -> user-<uid> (overrides user@ above).
      rule {
        source_labels = ["__meta_process_cgroup_path"]
        regex         = `0::/user\.slice/user-([0-9]+)\.slice(?:/.*)?`
        target_label  = "service_name"
        replacement   = "user-$1"
      }
    ${lib.concatMapStrings (user: ''
      rule {
        source_labels = ["service_name"]
        regex         = ${alloyLit "user-${toString user.uid}"}
        target_label  = "service_name"
        replacement   = ${alloyLit "user-${user.name}"}
      }
    '') namedUsers}
      // PID 1
      rule {
        source_labels = ["__meta_process_cgroup_path"]
        regex         = `0::/init\.scope`
        target_label  = "service_name"
        replacement   = "systemd"
      }

      // Fallback (scopes, machine.slice); matches targets_only=false default.
      rule {
        source_labels = ["service_name"]
        regex         = ""
        target_label  = "service_name"
        replacement   = "ebpf/unspecified"
      }

      // Strip path, Nix `.foo-wrapped` wrapper, and ` (deleted)` suffix.
      rule {
        source_labels = ["__meta_process_exe"]
        regex         = `.*/(?:\.([^/]+)-wrapped|([^/]+?))(?: \(deleted\))?`
        target_label  = "exe"
        replacement   = "$1$2"
      }
    }

    // Kernel threads (no exe, skipped above; live in root cgroup 0::/).
    discovery.process "kernel" {
      refresh_interval = ${alloyLit cfgP.refreshInterval}

      discover_config {
        cgroup_path  = true
        exe          = false
        commandline  = false
        container_id = false
        cwd          = false
        uid          = false
        username     = false
      }
    }

    discovery.relabel "kernel" {
      targets = discovery.process.kernel.targets

      rule {
        source_labels = ["__meta_process_cgroup_path"]
        regex         = "0::/"
        action        = "keep"
      }

      rule {
        target_label = "service_name"
        replacement  = "kernel"
      }
    }

    pyroscope.ebpf "host" {
      // Last target per pid wins ("units" overrides "kernel").
      targets = array.concat(
        discovery.relabel.kernel.output,
        discovery.relabel.units.output,
      )
      forward_to = [pyroscope.write.${writeLabel}.receiver]

      // Undocumented flag. false profiles undiscovered short-lived procs as
      // `ebpf/unspecified`; exited procs keep targets 2 intervals (our patch).
      targets_only = false

      sample_rate       = ${toString cfgP.sampleRate}
      collect_interval  = ${alloyLit cfgP.collectInterval}
      off_cpu_threshold = ${alloyLit cfgP.offCpuThreshold}

      // Drop pid label to avoid high cardinality (nix builds).
      pid_label = false
      // Our patch (nixos/pkgs/grafana-alloy).
      per_pid_profile = ${lib.boolToString cfgP.perPidProfile}
      // Strip C++/Rust params + template args (merges overloads).
      demangle = "simplified"

      ${lib.optionalString cfgP.testHooks ''
        // Patched test-only endpoints.
        test_hooks = true
      ''}

      // Default /tmp/symb-cache is lost on restart (PrivateTmp).
      symb_cache_path = "/var/cache/alloy/symb-cache"
      // Default true tries to pin /sys/fs/bpf/otel (root 0700 -> WARN); unused.
      obi_process_context_enabled = false
    }

    // Sync batched push per interval (our patch); no queue so slow pushes
    // don't stack. Partial ingest on failure means retries duplicate stored
    // series, so only retry likely-empty failures.
    pyroscope.write ${alloyLit writeLabel} {
      endpoint {
        url = ${alloyLit writeUrl}
    ${lib.optionalString (!isLocal) ''
      // Systemd credential (re-read per req, trimmed). 401 isn't retried.
      basic_auth {
        username      = ${alloyLit cfgRemote.username}
        password_file = sys.env("CREDENTIALS_DIRECTORY") + ${passwordPath}
      }
    ''}
        // Whole interval for first attempt so client timeouts aren't retried
        // (timed-out push may still be stored).
        remote_timeout = ${alloyLit cfgP.collectInterval}
        // Don't retry Connect ResourceExhausted (other series already stored).
        retry_on_http_429 = false
        // Retry transient errors (restart, 5xx) up to 3x w/in the interval.
        max_backoff_retries = 3
        min_backoff_period  = "1s"
        max_backoff_period  = "4s"
      }
      external_labels = {
        host = ${alloyLit cfgP.hostLabel},
      }
    }
  '';

  # Format + build-time validate w/ same Alloy binary (no BPF loaded).
  alloyConfigFile =
    pkgs.runCommand "config.alloy"
      {
        nativeBuildInputs = [ cfgAlloy.package ];
        configFile = pkgs.writeText "config.alloy.unformatted" alloyConfig;
      }
      ''
        alloy fmt "$configFile" > $out
        alloy validate $out
      '';

  pyroscopeAddr =
    "${cfgPyroSrv.http_listen_address}:" + toString cfgPyroSrv.http_listen_port;

  # Minimal non-root caps (tested in VM; CAP_SYS_RESOURCE omitted via
  # LimitMEMLOCK=infinity).
  # BPF + PERFMON + SYS_PTRACE can read any memory (~root-equivalent);
  # non-root only adds FS/syscall/ns confinement.
  alloyCaps = [
    "CAP_BPF" # load BPF progs + maps (fatal w/o)
    "CAP_PERFMON" # perf events, tracepoints, kprobes (fatal w/o)
    "CAP_SYS_PTRACE" # /proc/<pid>/{exe,maps,root}, process_vm_readv
    "CAP_CHECKPOINT_RESTORE" # /proc/<pid>/map_files (else SILENT [unknown])
    "CAP_DAC_READ_SEARCH" # tracefs + map_files (else SILENT [unknown])
    "CAP_SYSLOG" # /proc/kallsyms w/ kptr_restrict=1 (fatal w/o)
  ];
in
{
  options.services.phlip9-o11y.collector.profiling = {
    enable = lib.mkEnableOption "host eBPF profiling (Alloy -> Pyroscope)";

    sampleRate = lib.mkOption {
      type = lib.types.ints.positive;
      default = 49;
      description = "On-CPU samples/sec/CPU (odd to avoid lockstep aliasing).";
    };

    offCpuThreshold = lib.mkOption {
      type = lib.types.numbers.between 0 1;
      default = 0.02;
      description = ''
        Probability to sample blocked thread stacks (weighted by block time).
        0 = off. CPU cost scales w/ context switch rate.
      '';
    };

    collectInterval = lib.mkOption {
      type = lib.types.str;
      default = "15s";
      description = "Profile build + push interval (also per-push deadline).";
    };

    perPidProfile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Push 1 profile per (labels, pid) like upstream instead of merging per
        labels (Pyroscope merges them anyway). False avoids ~600-850 short-lived
        nix-build series per 15s on sauna.
      '';
    };

    refreshInterval = lib.mkOption {
      type = lib.types.str;
      default = "2s";
      description = ''
        /proc rescan interval for unit labels. Unseen procs land in
        `ebpf/unspecified` (~28% @ 10s, ~5% @ 2s, ~2.5% @ 1s on sauna nix
        builds; ~1.5ms/scan).
      '';
    };

    # Keep in sync w/ nixos/sauna/grafana/profiling.json (`host=~"$instance"`).
    hostLabel = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "`host` label on every profile.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:12345";
      description = "Loopback HTTP addr (/metrics, /-/ready, UI; no auth).";
    };

    testHooks = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = ''
        Tests only (patched). Exposes `/api/v0/component/pyroscope.ebpf.host/`
        flush/hold/inspect endpoints (no auth; held flush stalls profiling).
      '';
    };
  };

  config = lib.mkIf (cfgC.enable && cfgP.enable) {
    assertions = [
      {
        assertion = cfg.server.profiling.enable || !isLocal;
        message = ''
          phlip9-o11y: collector.profiling.enable needs a sink:
          server.profiling.enable on the same host, or collector.remote.
        '';
      }
    ];

    services.phlip9-o11y.collector.scrapeConfigs.alloy = {
      static_configs = hostTargets cfgP.listenAddress;
    };

    # --- Alloy --- #

    services.alloy = {
      enable = true;
      package = phlipPkgsNixos.grafana-alloy;
      extraFlags = [
        "--server.http.listen-addr=${cfgP.listenAddress}"
        # No telemetry to grafana.com.
        "--disable-reporting"
      ];
    };

    # Default configPath loads /etc/alloy/*.alloy.
    environment.etc."alloy/config.alloy" = {
      source = alloyConfigFile;
    };

    # Static user instead of DynamicUser for stable symb-cache ownership.
    users.users.alloy = {
      isSystemUser = true;
      group = "alloy";
    };
    users.groups.alloy = { };

    systemd.services.alloy = {
      # Restart rather than SIGHUP on config change; pyroscope.ebpf only
      # reloads targets + forward_to, all other args are startup-only.
      restartTriggers = [ alloyConfigFile ];
      reloadTriggers = lib.mkForce [ ];

      # Runaway guard (system.slice has no oomd/cap). Peaked at 1.4 GB on
      # sauna CI bursts (+ BPF maps). Omit MemoryHigh to OOM-kill fast rather
      # than crawl. Soft GC limit at 75% of MemoryMax (overrides Alloy's 90%).
      environment.GOMEMLIMIT = "1500MiB";

      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "alloy";
        Group = "alloy";
        # Drop module's systemd-journal group (Loki unused).
        SupplementaryGroups = lib.mkForce [ ];

        AmbientCapabilities = alloyCaps;
        CapabilityBoundingSet = alloyCaps;
        # Engine raises RLIMIT_MEMLOCK for BPF maps; replaces CAP_SYS_RESOURCE.
        LimitMEMLOCK = "infinity";

        # Symbol cache (symb_cache_path).
        CacheDirectory = "alloy";
        CacheDirectoryMode = "0700";

        # Remote basic auth password (toString prevents store copy).
        LoadCredential = lib.mkIf (!isLocal) [
          "${passwordCredential}:${toString cfgRemote.passwordFile}"
        ];

        # Hardening (VM-tested w/ eBPF profiling).
        DevicePolicy = "closed";
        # Allow any IP for remote DNS; next push retries w/o network-online.
        IPAddressAllow = lib.mkIf isLocal [ "localhost" ];
        IPAddressDeny = lib.mkIf isLocal [ "any" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        # See GOMEMLIMIT note above.
        MemoryMax = "2G";
        MemorySwapMax = "512M";
        # Ambient caps still apply after exec.
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        # cgroup paths come from /proc/<pid>/cgroup.
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelModules = true;
        # Must stay false or /proc/kallsyms is masked w/ 0000 (fatal).
        # Also breaks w/ ProtectKernelLogs (drops CAP_SYSLOG), ProcSubset=pid
        # (hides kallsyms), PrivateUsers (userns-scoped caps);
        # ProtectProc=invisible is a no-op w/ CAP_SYS_PTRACE.
        ProtectKernelTunables = false;
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          # kobject uevents for module (un)load (else WARN + stale module syms).
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        # Drop @privileged first, then re-add bpf + perf_event_open.
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "bpf perf_event_open"
        ];
        # Return EPERM so a failed tracefs mount(2) won't SIGSYS-kill Alloy.
        SystemCallErrorNumber = "EPERM";
        UMask = "0077";
      };
    };
  };
}
