# Shared o11y helpers for scrape targets and remote ingest URLs.
{ config }:

rec {
  exporterAddr = exporter: "${exporter.listenAddress}:${toString exporter.port}";

  # Label target w/ `instance=<hostname>` instead of `<addr>:<port>` so
  # Grafana `$instance` filters all jobs on a host (sync w/
  # nixos/sauna/grafana/*.json).
  hostTargets = target: [
    {
      targets = [ target ];
      labels.instance = config.networking.hostName;
    }
  ];

  exporterTargets = exporter: hostTargets (exporterAddr exporter);

  # Remote collector ingest URL layout (../server/ingest.nix). Paths are
  # relative to `prefix` (collector `remote.url` = `https://<vhost>/o11y`).
  ingest = {
    prefix = "/o11y";
    metricsPath = "/metrics/api/v1/write";
    # Alloy `pyroscope.write` appends `pushProcedure` to `profilesPath`.
    profilesPath = "/profiles";
    pushProcedure = "/push.v1.PusherService/Push";

    # Interpolated unescaped into VM's `extra_label=instance=<user>` query;
    # restrict to URL-safe hostname chars (superset of `networking.hostName`).
    usernameRegex = "^[A-Za-z0-9_-]+$";
  };
}
