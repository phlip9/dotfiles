# Helpers shared by the server + collector files: scrape targets for
# `collector.scrapeConfigs` entries, and the ingest endpoint's URL layout.
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

  # Ingest endpoint for remote collectors (server/ingest.nix). Paths are
  # relative to `ingest.prefix` on the server's vhost, which a collector's
  # `remote.url` points at (ex: `https://sauna.phlip9.com/o11y`).
  ingest = {
    prefix = "/o11y";
    # VictoriaMetrics' Prometheus remote write, for vmagent
    metricsPath = "/metrics/api/v1/write";
    # Base URL of Pyroscope's Connect API, for Alloy's `pyroscope.write`.
    # The client appends `/push.v1.PusherService/Push`.
    profilesPath = "/profiles";
    pushProcedure = "/push.v1.PusherService/Push";

    # Ingest usernames = hostnames. The server pastes the authenticated
    # username into VictoriaMetrics' URL unescaped
    # (`extra_label=instance=<username>`), so only URL-safe hostname
    # chars. Superset of `networking.hostName`'s chars.
    usernameRegex = "^[A-Za-z0-9_-]+$";
  };
}
