# Metrics observability module.
#
# Components:
# - VictoriaMetrics (metrics storage + scraper)
# - Grafana (visualization + dashboards)
# - prometheus-node-exporter (system metrics)
# - prometheus-nginx-exporter (nginx metrics, if nginx is enabled)
# - nginx virtualHost for Grafana (if grafana.domain is set)
#
# All services listen on localhost only. Only nginx is public-facing.
# Grafana secrets are injected via systemd LoadCredential and read
# via $__file{} providers from sops-nix managed secret files.
#
# See: doc/o11y/README.md
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.phlip9-o11y;

  # Credentials directory for the grafana.service unit.
  gfCreds = "/run/credentials/grafana.service";
in
{
  options.services.phlip9-o11y = {
    enable = lib.mkEnableOption "phlip9 metrics observability stack";

    grafana.domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "grafana.phlip9.com";
      description = ''
        Public domain for Grafana. When set, creates an nginx
        virtualHost with TLS (ACME) proxying to Grafana.
      '';
    };

    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "3";
      description = ''
        VictoriaMetrics data retention period.
        Default "3" = 3 months. Supports suffixes: h, d, w, y.
      '';
    };

    grafana.adminPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the Grafana admin password.
        In production, use config.sops.secrets.*.path.
      '';
    };

    grafana.secretKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the Grafana secret signing key.
        In production, use config.sops.secrets.*.path.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ===================================================================
    # VictoriaMetrics - metrics storage + scraper
    # ===================================================================
    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:8428";
      retentionPeriod = cfg.retentionPeriod;

      prometheusConfig = {
        scrape_configs = [
          {
            job_name = "victoriametrics";
            static_configs = [
              { targets = [ "127.0.0.1:8428" ]; }
            ];
          }
          {
            job_name = "node-exporter";
            static_configs = [
              { targets = [ "127.0.0.1:9100" ]; }
            ];
          }
          {
            job_name = "grafana";
            static_configs = [
              { targets = [ "127.0.0.1:3000" ]; }
            ];
          }
        ]
        ++ lib.optionals config.services.nginx.enable [
          {
            job_name = "nginx-exporter";
            static_configs = [
              { targets = [ "127.0.0.1:9113" ]; }
            ];
          }
        ];
      };
    };

    # ===================================================================
    # prometheus-node-exporter - system metrics
    # ===================================================================
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9100;
    };

    # ===================================================================
    # prometheus-nginx-exporter - nginx stub_status metrics
    # ===================================================================
    services.prometheus.exporters.nginx = lib.mkIf config.services.nginx.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9113;
    };
    # nginx-exporter needs stub_status exposed on localhost.
    services.nginx.statusPage = lib.mkIf config.services.nginx.enable true;

    # ===================================================================
    # Grafana - visualization + dashboards
    # ===================================================================
    #
    # Secrets loaded via systemd LoadCredential, referenced with
    # Grafana's $__file{path} provider.
    services.grafana = {
      enable = true;
      provision.enable = true;

      settings = {
        analytics.reporting_enabled = false;

        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = lib.mkIf (cfg.grafana.domain != null) cfg.grafana.domain;
        };

        security = {
          admin_user = lib.mkDefault "admin";
          admin_password = "$__file{${gfCreds}/admin-password}";
          secret_key = "$__file{${gfCreds}/secret-key}";
          disable_gravatar = true;
        };

        users = {
          allow_sign_up = false;
          allow_org_create = false;
        };
      };

      # Provision VictoriaMetrics as a Prometheus-type datasource.
      provision.datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "VictoriaMetrics";
            type = "prometheus";
            access = "proxy";
            uid = "victoriametrics";
            url = "http://127.0.0.1:8428";
            isDefault = true;
            editable = false;
          }
        ];
      };
    };

    # Inject Grafana secrets via systemd LoadCredential. The
    # grafana.service reads them at runtime from
    # /run/credentials/grafana.service/<name> via $__file{}.
    systemd.services.grafana.serviceConfig.LoadCredential = [
      "admin-password:${cfg.grafana.adminPasswordFile}"
      "secret-key:${cfg.grafana.secretKeyFile}"
    ];

    # ===================================================================
    # nginx - TLS termination + reverse proxy to Grafana
    # ===================================================================
    services.nginx.virtualHosts = lib.mkIf (cfg.grafana.domain != null) {
      ${cfg.grafana.domain} = {
        forceSSL = true;
        enableACME = true;

        locations."/" = {
          proxyPass = "http://127.0.0.1:3000";
          proxyWebsockets = true;
        };
      };
    };
  };
}
