# Continuous profiling for the phlip9-o11y stack.
#
# Pipeline:
#
#   Alloy pyroscope.ebpf --push--> Pyroscope --query--> Grafana (datasource +
#   (every process)                127.0.0.1:4040       Profiles Drilldown app)
#
# - Alloy (`collector`) samples on-CPU + off-CPU stacks of every process on
#   the host w/ eBPF, symbolizes them on the host, labels them w/ their
#   systemd unit, and pushes them to Pyroscope. Runs as the non-root `alloy`
#   user w/ a few ambient caps.
# - Pyroscope (127.0.0.1:4040) stores profiles on local disk and serves
#   queries. Single-node monolith (`-target=all`) w/ v2 storage.
# - Grafana gets a Pyroscope datasource, VictoriaMetrics scrapes Pyroscope's
#   + Alloy's `/metrics` (see ./default.nix).
#
# Pyroscope has no authn, so it only listens on loopback. Grafana is the
# authz boundary.
#
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
  cfgP = cfg.profiling;
  cfgC = cfgP.collector;
  cfgPyro = config.services.pyroscope;
  cfgPyroSrv = cfgPyro.settings.server;
  cfgAlloy = config.services.alloy;

  # Generate the YAML exactly like the nixpkgs module does.
  settingsFormat = pkgs.formats.yaml { };

  # Pyroscope's config parser rejects unknown keys, but only at startup. Parse
  # the generated config at build time instead. `-modules` loads the config,
  # lists the available modules, then exits, w/o starting anything.
  pyroscopeConfigCheck =
    pkgs.runCommand "pyroscope-config-check"
      {
        nativeBuildInputs = [ cfgPyro.package ];
        configFile = settingsFormat.generate "config.yaml" cfgPyro.settings;
      }
      ''
        pyroscope -config.file="$configFile" -modules > /dev/null
        touch $out
      '';

  # Alloy literals: strings, numbers. Alloy strings take JSON's escapes.
  alloyLit = builtins.toJSON;

  # Normal users w/ a fixed uid, to name their `user-<uid>.slice`s.
  namedUsers = lib.filter (user: user.isNormalUser && user.uid != null) (
    lib.attrValues config.users.users
  );

  # `0::/system.slice/[<parent>.slice/]<unit>.service[/<sub-cgroup>]`,
  # captures `<unit>`, or `<template>@` for templated units. RE2, anchored.
  systemUnitRegex = lib.concatStrings [
    "0::/system\\.slice/"
    # parent slices, ex: `system-getty.slice/`
    "(?:[^/]+\\.slice/)*"
    # unit name, or template prefix w/ `@`; then the instance
    "([^/@]+@?)[^/]*"
    "\\.service(?:/.*)?"
  ];

  # The collector's config, see `collector` options. `//` comments end up in
  # /etc/alloy/config.alloy, for whoever reads it there.
  alloyConfig = ''
    // Continuous profiling of every process on this host, see
    // nixos/mods/o11y/profiling.nix.
    //
    //   discovery.process -> discovery.relabel -> pyroscope.ebpf
    //   -> pyroscope.write -> Pyroscope

    // Every process w/ its exe + cgroup. Each refresh is a full /proc scan.
    discovery.process "all" {
      refresh_interval = ${alloyLit cfgC.refreshInterval}

      discover_config {
        cgroup_path = true
        exe         = true
        // Unused: skip their /proc reads
        commandline  = false
        container_id = false
        cwd          = false
        uid          = false
        username     = false
      }
    }

    // Label each process w/ its systemd unit (`service_name`) + exe. Only
    // labels w/o a `__` prefix reach Pyroscope.
    discovery.relabel "units" {
      targets = discovery.process.all.targets

      // `0::/system.slice/[<parent>.slice/]<unit>.service[/<sub-cgroup>]`
      // -> `<unit>`. Templated units collapse into their template, ex:
      // `getty@tty1` -> `getty@`, so per-instance units (`sshd@<conn>`)
      // don't create a series each.
      rule {
        source_labels = ["__meta_process_cgroup_path"]
        regex         = ${alloyLit systemUnitRegex}
        target_label  = "service_name"
      }

      // User sessions + user managers:
      // `0::/user.slice/user-<uid>.slice/...` -> `user-<uid>`
      rule {
        source_labels = ["__meta_process_cgroup_path"]
        regex         = `0::/user\.slice/user-([0-9]+)\.slice(?:/.*)?`
        target_label  = "service_name"
        replacement   = "user-$1"
      }
    ${lib.concatMapStrings (user: ''
      // `user-${toString user.uid}` -> `user-${user.name}`
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

      // Anything else (scopes, machine.slice, ...): same name as processes
      // that discovery hasn't seen yet, see `targets_only` below.
      rule {
        source_labels = ["service_name"]
        regex         = ""
        target_label  = "service_name"
        replacement   = "ebpf/unspecified"
      }

      // Basename: `/nix/store/<hash>-foo/bin/.foo-wrapped (deleted)` -> `foo`
      rule {
        source_labels = ["__meta_process_exe"]
        regex         = `.*/(?:\.([^/]+)-wrapped|([^/]+?))(?: \(deleted\))?`
        target_label  = "exe"
        replacement   = "$1$2"
      }
    }

    pyroscope.ebpf "host" {
      targets    = discovery.relabel.units.output
      forward_to = [pyroscope.write.local.receiver]

      // Undocumented. `true` (default) only profiles processes in `targets`.
      // `false` profiles every process; ones w/o a target (not yet
      // discovered, < 1 refresh old) get service_name="ebpf/unspecified".
      targets_only = false

      sample_rate       = ${toString cfgC.sampleRate}
      collect_interval  = ${alloyLit cfgC.collectInterval}
      off_cpu_threshold = ${alloyLit cfgC.offCpuThreshold}

      // A `pid` label per sample: high cardinality (nix builds), bigger
      // profiles. Labels stay per unit + exe.
      pid_label = false
      // C++/Rust names w/o params or template args: short flame graph
      // frames. Overloads merge.
      demangle = "simplified"

      // Default /tmp/symb-cache is private + lost on restart (PrivateTmp)
      symb_cache_path = "/var/cache/alloy/symb-cache"
      // Default `true` pins maps in /sys/fs/bpf/otel (root 0700), which
      // fails non-root w/ a WARN. We don't use OTel span/trace IDs.
      obi_process_context_enabled = false
    }

    pyroscope.write "local" {
      endpoint {
        url = ${alloyLit "http://${pyroscopeAddr}"}
      }
      external_labels = {
        host = ${alloyLit cfgC.hostLabel},
      }
    }
  '';

  # Format the rendered config (alignment, interpolated indents), then
  # validate it at build time, w/ the same binary as the unit: syntax,
  # component args. Doesn't load any BPF.
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

  # Pyroscope's on-disk size, for node-exporter's textfile collector. All
  # Pyroscope state is under its StateDirectory (DynamicUser: really
  # /var/lib/private/pyroscope).
  pyroscopeDu = pkgs.writeShellApplication {
    name = "pyroscope-du";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      bytes=$(du -sB1 /var/lib/pyroscope/ | cut -f1)
      # Write + rename: node-exporter never reads a partial file
      cat > "$RUNTIME_DIRECTORY/pyroscope.prom.tmp" <<EOF
      # HELP pyroscope_data_bytes Disk usage of Pyroscope's data dir.
      # TYPE pyroscope_data_bytes gauge
      pyroscope_data_bytes $bytes
      EOF
      mv "$RUNTIME_DIRECTORY/pyroscope.prom.tmp" \
        "$RUNTIME_DIRECTORY/pyroscope.prom"
    '';
  };

  pyroscopeAddr =
    "${cfgPyroSrv.http_listen_address}:" + toString cfgPyroSrv.http_listen_port;

  # Minimal caps for `pyroscope.ebpf` + `discovery.process` as non-root.
  # Found by dropping one at a time in a NixOS VM (kernel 7.3, sauna's
  # sysctls); every one is load-bearing. The Alloy docs' list also has
  # CAP_SYS_RESOURCE, only needed w/o `LimitMEMLOCK=infinity`.
  #
  # CAVEAT: BPF + PERFMON + SYS_PTRACE can read any kernel/user memory, so
  # this is ~root-equivalent. Non-root buys FS/syscall/namespace confinement
  # + no DAC_OVERRIDE/SYS_ADMIN, not a privilege boundary.
  alloyCaps = [
    # load BPF progs + maps. Fatal w/o.
    "CAP_BPF"
    # cpu-wide perf events, tracepoints, kprobes. Fatal w/o.
    "CAP_PERFMON"
    # other users' /proc/<pid>/{exe,maps,root}, process_vm_readv
    # (interpreter frames). W/o: their processes aren't profiled at all.
    "CAP_SYS_PTRACE"
    # open /proc/<pid>/map_files/* (ELF access for unwinding + symbols).
    # W/o: SILENT failure, user frames turn `[unknown]`.
    "CAP_CHECKPOINT_RESTORE"
    # traverse 0700 tracefs (off-CPU) + other users' 0500
    # /proc/<pid>/map_files. W/o: SILENT `[unknown]` user frames.
    "CAP_DAC_READ_SEARCH"
    # real addrs in /proc/kallsyms under kptr_restrict=1. Fatal w/o.
    "CAP_SYSLOG"
  ];
in
{
  options.services.phlip9-o11y.profiling = {
    enable = lib.mkEnableOption "continuous profiling (Pyroscope)";

    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      example = "90d";
      description = ''
        Pyroscope profile retention period. Pyroscope's v2 storage only
        supports time-based retention, no size cap, so pick this from the
        measured bytes/day. "0" = forever.

        Deletion lags behind: nominally a 6h index partition + 6h grace + the
        15min cleanup cadence, after which compaction workers physically
        delete the data. A cleanup or compaction backlog keeps data longer.
        Not a disk-usage bound.
      '';
    };

    collector = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Profile every process on this host w/ Alloy's `pyroscope.ebpf`
          and push the profiles to the local Pyroscope.
        '';
      };

      sampleRate = lib.mkOption {
        type = lib.types.ints.positive;
        default = 49;
        description = ''
          On-CPU stack samples per second, per CPU. Odd, so sampling
          doesn't run in lockstep w/ periodic work.
        '';
      };

      offCpuThreshold = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        default = 0.02;
        description = ''
          Probability to record the stack of a thread that blocks (context
          switch), weighted by time blocked, as the `offcpu` profile type.
          0 = off. CPU cost scales w/ the host's context switch rate x this.
        '';
      };

      collectInterval = lib.mkOption {
        type = lib.types.str;
        default = "15s";
        description = ''
          How often Alloy builds + pushes one profile per (labels, pid).
          Also the deadline for each round of pushes.
        '';
      };

      refreshInterval = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = ''
          How often Alloy rescans /proc for processes to label w/ their
          unit. Each scan reads a few /proc files per process. Processes
          younger than one scan are still profiled, but as
          `service_name="ebpf/unspecified"`, so shorter = better attribution
          of short-lived processes (ex: nix builds) for more CPU.
        '';
      };

      hostLabel = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        defaultText = lib.literalExpression "config.networking.hostName";
        description = "`host` label on every profile.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:12345";
        description = ''
          Alloy HTTP server: `/metrics`, `/-/ready`, debug UI. No authn,
          keep it on loopback.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfgP.enable) {
    # ===================================================================
    # Pyroscope - profile storage + queries
    # ===================================================================
    services.pyroscope = {
      enable = true;
      settings = {
        # Default `v1-v2-dual` also loads every v1 module (ingester,
        # compactor, store-gateway, querier, ...) to read old v1 data. We
        # have none.
        architecture_storage = "v2";

        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 4040;
          # Default "" listens on all interfaces. Pyroscope's internal
          # metastore + query-backend clients dial `localhost:9095`.
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9095;
        };

        # Local disk. Every default data dir is relative (`./data/...`) and
        # the nixpkgs unit's WorkingDirectory is its StateDirectory, so all
        # state lands in /var/lib/pyroscope/data.
        storage.backend = "filesystem";

        limits.retention_period = cfgP.retentionPeriod;

        # Each ring member advertises an IP that it picks from a list of
        # private interfaces, w/ a fallback to `eth0,en0`. sauna has only
        # `eno1` w/ a public IP, so these components fail at startup w/ "no
        # useable address found for interfaces [eth0 en0]". Pin them all to
        # loopback; there are no other members to reach us.
        distributor.ring.instance_addr = "127.0.0.1";
        frontend.instance_addr = "127.0.0.1";
        overrides_exporter.ring.instance_addr = "127.0.0.1";
        segment_writer.lifecycler.address = "127.0.0.1";
        # Rings gossip over memberlist, which defaults to 0.0.0.0:7946.
        memberlist.bind_addr = [ "127.0.0.1" ];

        # `/ready` waits this long after the metastore (15s) and segment
        # writer (30s) are up, so rolling updates give other cluster members
        # time to see them. A single node has no one to wait for.
        metastore.min_ready_duration = "0s";
        segment_writer.lifecycler.min_ready_duration = "0s";

        # Compaction runs up to #CPUs jobs at once by default. sauna's 12
        # threads are shared w/ CI, and a single node's few blocks/min don't
        # need more.
        # = `-compaction-worker.job-concurrency`
        compaction_worker.job_capacity = 2;

        # `info` logs 4 lines per query (query start/finish, params, weight)
        # + compaction polls every few seconds.
        server.log_level = "warn";

        # The monolith otherwise pushes profiles of itself to itself.
        self_profiling.disable_push = true;
        # No anonymous usage stats to grafana.com
        analytics.reporting_enabled = false;
      };
    };

    system.checks = [ pyroscopeConfigCheck ];

    # Pyroscope has no metric for its on-disk size, so export `du` of its
    # data dir via node-exporter's textfile collector. For the
    # PyroscopeDiskHigh alert (./rules.nix).
    systemd.services.pyroscope-du = {
      description = "Export Pyroscope's disk usage to node-exporter";
      after = [ "pyroscope.service" ];
      wantedBy = [ "multi-user.target" ];
      startAt = "*:0/15";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pyroscopeDu;
        # root, but only to read Pyroscope's 0700 dirs. Not DynamicUser: it
        # moves a preserved RuntimeDirectory to 0700 /run/private.
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        # = node-exporter's `--collector.textfile.directory`
        RuntimeDirectory = "pyroscope-du";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
        UMask = "0022";
        IPAddressDeny = [ "any" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "none" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
    services.prometheus.exporters.node.extraFlags = [
      "--collector.textfile.directory=/run/pyroscope-du"
    ];

    # TODO(phlip9): MemoryMax for pyroscope + alloy once measured on sauna.
    # VM test (2 vCPU, 1 busy unit): pyroscope ~100 MB RSS idle; alloy ~255
    # MB RSS steady at 97 Hz + off-CPU 0.5, startup peak (BPF load + first
    # symbolization) up to 455 MB.

    # Hardening. Only talks to itself + its clients on loopback. The nixpkgs
    # module already sets DynamicUser, DevicePolicy=closed, StateDirectory,
    # and ProtectSystem=full (tightened below).
    systemd.services.pyroscope.serviceConfig = {
      CapabilityBoundingSet = [ "" ];
      IPAddressAllow = [ "localhost" ];
      IPAddressDeny = [ "any" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      PrivateUsers = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = lib.mkForce "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        # Every ring config lists the network interfaces for its default
        # instance address, even when pinned, and logs a warning on failure.
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
      ];
      UMask = "0077";
    };

    # ===================================================================
    # Alloy - eBPF profiler for every process on the host
    # ===================================================================
    services.alloy = lib.mkIf cfgC.enable {
      enable = true;
      package = phlipPkgsNixos.grafana-alloy;
      extraFlags = [
        "--server.http.listen-addr=${cfgC.listenAddress}"
        # No anonymous usage stats to grafana.com
        "--disable-reporting"
      ];
    };

    # The module's default `configPath` loads every /etc/alloy/*.alloy and
    # reloads Alloy when one changes.
    environment.etc."alloy/config.alloy" = lib.mkIf cfgC.enable {
      source = alloyConfigFile;
    };

    # Static user instead of the module's DynamicUser: stable owner for the
    # symbol cache across restarts, and an explicit identity to audit.
    users.users.alloy = lib.mkIf cfgC.enable {
      isSystemUser = true;
      group = "alloy";
    };
    users.groups.alloy = lib.mkIf cfgC.enable { };

    systemd.services.alloy.serviceConfig = lib.mkIf cfgC.enable {
      DynamicUser = lib.mkForce false;
      User = "alloy";
      Group = "alloy";
      # Module adds `systemd-journal` for Loki log forwarding; unused
      SupplementaryGroups = lib.mkForce [ ];

      AmbientCapabilities = alloyCaps;
      CapabilityBoundingSet = alloyCaps;
      # The engine raises RLIMIT_MEMLOCK at startup, up to the hard limit.
      # systemd's default 8M hard limit fails BPF map creation; this
      # replaces CAP_SYS_RESOURCE.
      LimitMEMLOCK = "infinity";

      # Symbol cache, see `symb_cache_path`
      CacheDirectory = "alloy";
      CacheDirectoryMode = "0700";

      # Hardening. Each setting below was tested w/ eBPF profiling in a VM.
      DevicePolicy = "closed";
      # Only pushes to Pyroscope + serves /metrics on loopback
      IPAddressAllow = [ "localhost" ];
      IPAddressDeny = [ "any" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      # Ambient caps still apply after exec
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      # cgroup paths come from /proc/<pid>/cgroup
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelModules = true;
      # MUST stay off: `true` mounts an empty, mode 0000 file over
      # /proc/kallsyms. The engine reads it (DAC_READ_SEARCH), finds no
      # addresses, and fails to start: "failed to read kernel symbols:
      # unable to read kallsyms addresses". W/o CAP_DAC_OVERRIDE or
      # CAP_SYS_ADMIN the alloy user can't write /proc/sys + /sys anyway.
      ProtectKernelTunables = false;
      # Also MUST stay off, all fatal for the same reason (no kallsyms):
      # - ProtectKernelLogs: drops CAP_SYSLOG from the bounding set
      # - ProcSubset=pid: hides /proc/kallsyms
      # And:
      # - PrivateUsers: caps only apply in the child userns, so other
      #   users' /proc/<pid>/exe is unreadable
      # - PrivatePIDs: can't see other processes
      # - PrivateNetwork: can't reach Pyroscope
      # - ProtectProc=invisible: works, but a no-op w/ CAP_SYS_PTRACE
      ProtectSystem = "strict";
      RemoveIPC = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        # kallsyms monitor: kobject uevents on kernel module (un)load.
        # W/o: WARN at startup + stale module symbols.
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      # Order matters: allow-list, drop @privileged (has bpf), then re-add.
      # perf_event_open is in @debug, but nothing else from it is needed.
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "bpf perf_event_open"
      ];
      # EPERM, not SIGSYS. Ex: if tracefs is unreadable, Alloy tries to
      # mount(2) it; that should fail, not kill Alloy.
      SystemCallErrorNumber = "EPERM";
      UMask = "0077";
    };
  };
}
