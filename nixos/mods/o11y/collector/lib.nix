# Scrape target helpers for `collector.scrapeConfigs` entries. Server and
# collector files both build their jobs w/ these.
#
# Usage: `o11yLib = import ../collector/lib.nix { inherit config; };`
{ config }:

rec {
  # `<listenAddress>:<port>` of a `services.prometheus.exporters.<name>`.
  exporterAddr = exporter: "${exporter.listenAddress}:${toString exporter.port}";

  # A scrape target on this host, labeled `instance=<hostname>` instead of
  # the default `<loopback addr>:<port>`. Every job on a host then shares
  # one `instance`, so one dashboard `$instance` var filters them all.
  # Keep in sync: nixos/sauna/grafana/*.json `$instance` var
  # (label_values(node_uname_info, instance)) + `instance=~"$instance"`
  # filters.
  hostTargets = target: [
    {
      targets = [ target ];
      labels.instance = config.networking.hostName;
    }
  ];

  # `hostTargets` for a `services.prometheus.exporters.<name>`.
  exporterTargets = exporter: hostTargets (exporterAddr exporter);
}
