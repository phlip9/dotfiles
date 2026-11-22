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

  settingsFormat = pkgs.formats.yaml { };

  # Build-time config validation (`-modules` parses YAML and exits).
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

  # Export Pyroscope's data dir size for node-exporter's textfile collector.
  pyroscopeDu = pkgs.writeShellApplication {
    name = "pyroscope-du";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      bytes=$(du -sB1 /var/lib/pyroscope/ | cut -f1)
      # Atomic write so node-exporter never reads a partial file.
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
        Profile retention period ("0" = forever). Pyroscope v2 has no size cap;
        deletion lags behind (6h partition + 6h grace + compaction), so this is
        not a strict disk bound.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfgP.enable) {
    services.phlip9-o11y.collector.scrapeConfigs.pyroscope = {
      static_configs = hostTargets pyroscopeAddr;
    };

    # --- Pyroscope --- #

    services.pyroscope = {
      enable = true;
      settings = {
        # Skip legacy v1 modules loaded by default `v1-v2-dual`.
        architecture_storage = "v2";

        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 4040;
          # Default "" binds all interfaces; internal clients dial :9095.
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9095;
        };

        # Lands in StateDirectory (/var/lib/pyroscope/data) via relative ./data.
        storage.backend = "filesystem";

        limits.retention_period = cfgP.retentionPeriod;
        # Above default 2 MiB burst so Alloy's batched 15s CI-peak push
        # (~2.4 MB uncompressed) isn't rate-limited and dropped.
        limits.ingestion_burst_size_mb = 8;

        # Pin ring addrs to loopback; default private/eth0/en0 detection fails
        # on hosts w/ only a public interface (ex: sauna's `eno1`).
        distributor.ring.instance_addr = "127.0.0.1";
        frontend.instance_addr = "127.0.0.1";
        overrides_exporter.ring.instance_addr = "127.0.0.1";
        segment_writer.lifecycler.address = "127.0.0.1";
        # Memberlist gossip defaults to 0.0.0.0:7946.
        memberlist.bind_addr = [ "127.0.0.1" ];

        # Skip multi-node rolling-update readiness delays (15s/30s defaults).
        metastore.min_ready_duration = "0s";
        segment_writer.lifecycler.min_ready_duration = "0s";

        # Defaults to #CPUs; cap so compaction doesn't contend w/ CI builds.
        compaction_worker.job_capacity = 2;

        # Silence chatty per-query + compaction poll info logs.
        server.log_level = "warn";

        # Prevent monolith from pushing self-profiles to itself.
        self_profiling.disable_push = true;
        analytics.reporting_enabled = false;
      };
    };

    system.checks = [ pyroscopeConfigCheck ];

    # Pyroscope has no disk-size metric; feeds PyroscopeDiskHigh (./rules.nix).
    systemd.services.pyroscope-du = {
      description = "Export Pyroscope's disk usage to node-exporter";
      after = [ "pyroscope.service" ];
      wantedBy = [ "multi-user.target" ];
      startAt = "*:0/15";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pyroscopeDu;
        # Root w/ CAP_DAC_READ_SEARCH to read Pyroscope's 0700 dir (DynamicUser
        # would move preserved RuntimeDirectory into 0700 /run/private).
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        # Matches node-exporter --collector.textfile.directory below.
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

    # Runaway guard (system.slice has no oomd/cap). Measured peak on sauna is
    # 0.9 GB RSS (1.5 GB cgroup w/ cache) + 1-2 GB for big flame graph queries.
    # Omit MemoryHigh to OOM-kill fast rather than crawl; soft GC limit at 75%
    # of MemoryMax.
    systemd.services.pyroscope.environment.GOMEMLIMIT = "3GiB";

    # Hardening (loopback only; nixpkgs sets DynamicUser + DevicePolicy).
    systemd.services.pyroscope.serviceConfig = {
      CapabilityBoundingSet = [ "" ];
      IPAddressAllow = [ "localhost" ];
      IPAddressDeny = [ "any" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      # See GOMEMLIMIT note above.
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
        # Ring configs enumerate net interfaces even when pinned (else WARN).
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
