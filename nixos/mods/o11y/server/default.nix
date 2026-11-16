# o11y server: metrics storage + query.
#
# Components:
# - VictoriaMetrics (metrics storage + query, remote write ingest)
# - prometheus-blackbox-exporter (HTTPS probes of `probes`, if any)
# - Grafana (visualization + dashboards): see ./grafana.nix
# - Alerting (vmalert + Alertmanager): see ./alerting.nix
# - Profiling (Pyroscope): see ./pyroscope.nix
# - Ingest for remote collectors (nginx): see ./ingest.nix
#
# Each component adds its own self-scrape job to `collector.scrapeConfigs`.
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
  cfgVm = config.services.victoriametrics;
  cfgBlackbox = config.services.prometheus.exporters.blackbox;

  inherit (import ../collector/lib.nix { inherit config; })
    exporterAddr
    hostTargets
    ;

  # blackbox_exporter: ping https:// URLs and report `probe_success` and
  # `probe_ssl_earliest_cert_expiry` metrics.
  # See: <blackbox_exporter>/CONFIGURATION.md
  blackboxConfig = (pkgs.formats.yaml { }).generate "blackbox.yml" {
    modules.https_2xx = {
      prober = "http";
      # < VM's default 10s scrape timeout
      timeout = "5s";
      http.fail_if_not_ssl = true;
    };
  };
in
{
  imports = [
    ./grafana.nix
    ./alerting.nix
    ./pyroscope.nix
    ./ingest.nix
  ];

  options.services.phlip9-o11y.server = {
    enable = lib.mkEnableOption ''
      the o11y server: metrics storage + query (VictoriaMetrics), dashboards
      (Grafana), and optionally alerting + profile storage
    '';

    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "3";
      description = ''
        VictoriaMetrics data retention period.
        Default "3" = 3 months. Supports suffixes: h, d, w, y.
      '';
    };

    probes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "https://grafana.phlip9.com/api/health" ];
      description = ''
        HTTPS URLs that blackbox_exporter probes on every scrape.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ===================================================================
    # VictoriaMetrics - metrics storage + query
    # ===================================================================
    # No `prometheusConfig`: its built-in scraper stays off. The collector's
    # vmagent scrapes + remote-writes to `/api/v1/write`, see
    # ../collector/default.nix.
    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:8428";
      retentionPeriod = cfg.retentionPeriod;
    };

    # ===================================================================
    # prometheus-blackbox-exporter - HTTPS probes + cert expiry
    # ===================================================================
    services.prometheus.exporters.blackbox = lib.mkIf (cfg.probes != [ ]) {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9115;
      configFile = blackboxConfig;
    };

    services.phlip9-o11y.collector.scrapeConfigs = {
      victoriametrics.static_configs = hostTargets cfgVm.listenAddress;

      # Probe each URL through blackbox_exporter's `/probe?target=<url>`,
      # labeled `instance=<url>`, not the hostname: the probe alerts name
      # the URL.
      blackbox = lib.mkIf (cfg.probes != [ ]) {
        metrics_path = "/probe";
        params.module = [ "https_2xx" ];
        static_configs = [ { targets = cfg.probes; } ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = exporterAddr cfgBlackbox;
          }
        ];
      };
    };
  };
}
