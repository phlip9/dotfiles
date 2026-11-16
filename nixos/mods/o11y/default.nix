# Observability module: metrics, dashboards, alerting, profiling. Two roles
# under `services.phlip9-o11y`, each w/ its own `enable`:
#
# - `server` (./server): storage, query, dashboards, alerting
#   - VictoriaMetrics (metrics storage + query): ./server/default.nix
#   - prometheus-blackbox-exporter (HTTPS probes): ./server/default.nix
#   - Grafana + Git Sync + nginx vhost: ./server/grafana.nix
#   - vmalert + Alertmanager: ./server/alerting.nix
#   - Pyroscope (profile storage): ./server/pyroscope.nix
#   - nginx ingest endpoints for remote collectors: ./server/ingest.nix
# - `collector` (./collector): this host's metrics + profiles
#   - prometheus-{node,nginx,postgres}-exporter: ./collector/default.nix
#   - vmagent: scrapes `collector.scrapeConfigs`: ./collector/default.nix
#   - nixos-exporter: ./collector/nixos-exporter.nix
#   - Alloy eBPF profiler: ./collector/alloy.nix
#
# All services listen on localhost only. Only nginx is public-facing.
#
# See: doc/o11y/README.md
{
  imports = [
    ./server
    ./collector
  ];
}
