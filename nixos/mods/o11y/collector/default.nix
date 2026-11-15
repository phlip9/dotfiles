# o11y collector: per-host exporters.
#
# Components:
# - prometheus-node-exporter (system metrics)
# - prometheus-nginx-exporter (nginx metrics, if nginx is enabled)
# - prometheus-postgres-exporter (postgres metrics, if postgres is enabled)
# - rbitcoin node metrics (if rbitcoin is enabled)
# - nixos-exporter (boots, generation, pending reboot): see ./nixos-exporter.nix
# - Alloy eBPF profiler: see ./alloy.nix
#
# See: doc/o11y/README.md
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.phlip9-o11y;
  cfgRbitcoin = config.services.rbitcoin;
in
{
  imports = [
    ./nixos-exporter.nix
    ./alloy.nix
  ];

  config = lib.mkIf cfg.enable {
    # ===================================================================
    # prometheus-node-exporter - system metrics
    # ===================================================================
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9100;
      enabledCollectors = [
        "systemd"
        "processes"
      ];
    };

    # ===================================================================
    # prometheus-nginx-exporter - nginx stub_status metrics
    # ===================================================================
    services.prometheus.exporters.nginx = lib.mkIf config.services.nginx.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9113;
    };
    # nginx-exporter needs stub_status exposed on localhost. Its vhost is
    # bound to loopback in the nginx section below.
    services.nginx.statusPage = lib.mkIf config.services.nginx.enable true;

    # ===================================================================
    # prometheus-postgres-exporter - postgres metrics
    # ===================================================================
    services.prometheus.exporters.postgres =
      lib.mkIf config.services.postgresql.enable
        {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9187;
          runAsLocalSuperUser = true;
          # PostgreSQL 17 moved checkpoint stats out of pg_stat_bgwriter into
          # pg_stat_checkpointer. Keep in sync:
          # nixos/sauna/grafana/postgres-overview.json "Buffers".
          extraFlags = [ "--collector.stat_checkpointer" ];
        };

    # ===================================================================
    # rbitcoin - node metrics
    # ===================================================================
    # `/metrics` needs the loopback health listener.
    services.rbitcoin = lib.mkIf cfgRbitcoin.enable {
      health.enable = lib.mkDefault true;
      metrics = lib.mkDefault true;
    };

    # ===================================================================
    # nginx - stub_status vhost
    # ===================================================================
    # The upstream stub_status vhost listens on all addresses. Only the local
    # exporter needs it. Upstream default causes lots of spam logs from bots.
    # NOTE(phlip9): upstream already has an ip whitelist for
    # `virtualHosts.localhost`, this is just for cleaning up our logs.
    services.nginx.virtualHosts = lib.mkIf config.services.nginx.enable {
      localhost.listenAddresses = [
        "127.0.0.1"
        "[::1]"
      ];
    };
  };
}
