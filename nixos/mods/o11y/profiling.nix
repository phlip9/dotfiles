# Continuous profiling for the phlip9-o11y stack.
#
# Pipeline:
#
#   (profilers) --push--> Pyroscope --query--> Grafana (datasource +
#                         127.0.0.1:4040       Profiles Drilldown app)
#
# - Pyroscope (127.0.0.1:4040) stores profiles on local disk and serves
#   queries. Single-node monolith (`-target=all`) w/ v2 storage.
# - Grafana gets a Pyroscope datasource, VictoriaMetrics scrapes Pyroscope's
#   `/metrics` (see ./default.nix).
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
  cfg = config.services.phlip9-o11y;
  cfgP = cfg.profiling;
  cfgPyro = config.services.pyroscope;

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
        measured bytes/day. Disk usage trails it by up to ~12h: the metastore
        drops whole 6h partitions, after a 6h grace period. "0" = forever.
      '';
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

        # The monolith otherwise pushes profiles of itself to itself.
        self_profiling.disable_push = true;
        # No anonymous usage stats to grafana.com
        analytics.reporting_enabled = false;
      };
    };

    system.checks = [ pyroscopeConfigCheck ];

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
  };
}
