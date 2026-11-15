# Observability module: metrics, dashboards, alerting, profiling.
#
# - ./server: storage, query, dashboards, alerting
#   - VictoriaMetrics (metrics storage + scraper): ./server/default.nix
#   - prometheus-blackbox-exporter (HTTPS probes): ./server/default.nix
#   - Grafana + Git Sync + nginx vhost: ./server/grafana.nix
#   - vmalert + Alertmanager: ./server/alerting.nix
#   - Pyroscope (profile storage): ./server/pyroscope.nix
# - ./collector: per-host metrics + profiles
#   - prometheus-{node,nginx,postgres}-exporter: ./collector/default.nix
#   - nixos-exporter: ./collector/nixos-exporter.nix
#   - Alloy eBPF profiler: ./collector/alloy.nix
#
# All services listen on localhost only. Only nginx is public-facing.
#
# See: doc/o11y/README.md
{ lib, ... }:

{
  imports = [
    ./server
    ./collector
  ];

  options.services.phlip9-o11y = {
    enable = lib.mkEnableOption "phlip9 metrics observability stack";
  };
}
