# o11y server: Pyroscope (continuous profiling storage + queries).
#
# Pipeline:
#
#   Alloy pyroscope.ebpf --push--> Pyroscope --query--> Grafana (datasource +
#   (every process)                127.0.0.1:4040       Profiles Drilldown app)
#
# - Alloy (see ../collector/alloy.nix) pushes profiles of every process.
# - Pyroscope (127.0.0.1:4040) stores profiles on local disk and serves
#   queries. Single-node monolith (`-target=all`) w/ v2 storage.
# - Grafana gets a Pyroscope datasource (see ./grafana.nix).
# - Pyroscope's own `/metrics` are scraped as job `pyroscope`.
#
# Pyroscope has no authn, so it only listens on loopback. Grafana is the
# authz boundary.
#
# See: doc/o11y/README.md
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.phlip9-o11y.server;
  cfgP = cfg.profiling;
  cfgPyro = config.services.pyroscope;
  cfgPyroSrv = cfgPyro.settings.server;
  pyroscopeAddr =
    "${cfgPyroSrv.http_listen_address}:" + toString cfgPyroSrv.http_listen_port;

  inherit (import ../collector/lib.nix { inherit config; }) hostTargets;

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

in
{
  options.services.phlip9-o11y.server.profiling = {
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
  };

  config = lib.mkIf (cfg.enable && cfgP.enable) {
    services.phlip9-o11y.collector.scrapeConfigs.pyroscope = {
      static_configs = hostTargets pyroscopeAddr;
    };

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
        # The ingestion rate limiter (default 4 MiB/s, 2 MiB burst) counts
        # uncompressed bytes, per series. Alloy pushes a collect interval's
        # profiles in one request: ~1.2 MB (~2.4 MB w/ a 2x estimate error)
        # per 15s at a CI peak on sauna, w/ one merged profile per labels.
        # Rate limited series are dropped, not retried (see
        # ../collector/alloy.nix). Burst headroom for a whole interval;
        # Alloy is the only client.
        # = `-distributor.ingestion-burst-size-mb`
        limits.ingestion_burst_size_mb = 8;

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

    # Memory cap, a runaway guard: Pyroscope runs in system.slice, which has
    # no cap of its own and isn't watched by oomd. Hitting MemoryMax
    # OOM-kills it and systemd restarts it: a few seconds w/o ingest.
    # Measured on sauna (2026-11, 2 hosts): daily max RSS 180-380 MB, worst
    # 0.9 GB, cgroup peak 1.5 GB incl. page cache (counted, but reclaimed
    # before a kill). A big flame graph query adds 1-2 GB.
    # No MemoryHigh: it throttles a runaway into a slow crawl instead of a
    # prompt kill. Small swap cap for the same reason.
    # GOMEMLIMIT, Go's soft limit, at 75% of the cap: GC harder before the
    # kill, so a legitimate burst is less likely to hit it.
    systemd.services.pyroscope.environment.GOMEMLIMIT = "3GiB";

    # Hardening. Only talks to itself + its clients on loopback. The nixpkgs
    # module already sets DynamicUser, DevicePolicy=closed, StateDirectory,
    # and ProtectSystem=full (tightened below).
    systemd.services.pyroscope.serviceConfig = {
      CapabilityBoundingSet = [ "" ];
      IPAddressAllow = [ "localhost" ];
      IPAddressDeny = [ "any" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      # Memory cap, see above
      MemoryMax = "4G";
      MemorySwapMax = "512M";
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
  };
}
