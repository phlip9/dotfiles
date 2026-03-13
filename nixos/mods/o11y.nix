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
  pkgs,
  ...
}:

let
  inherit (builtins) toString;

  cfg = config.services.phlip9-o11y;

  cfgVm = config.services.victoriametrics;
  cfgGf = config.services.grafana;
  cfgGfSrv = cfgGf.settings.server;
  gfAddr = "${cfgGfSrv.http_addr}:${toString cfgGfSrv.http_port}";

  exporterAddr = exporter: "${exporter.listenAddress}:${toString exporter.port}";
  exporterTargets = exporter: [
    { targets = [ (exporterAddr exporter) ]; }
  ];

  # Credentials directory for the grafana.service unit.
  gfCredsDir = "/run/credentials/grafana.service";
in
{
  options.services.phlip9-o11y = {
    enable = lib.mkEnableOption "phlip9 metrics observability stack";

    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "3";
      description = ''
        VictoriaMetrics data retention period.
        Default "3" = 3 months. Supports suffixes: h, d, w, y.
      '';
    };

    grafana = {
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "grafana.phlip9.com";
        description = ''
          Public domain for Grafana. When set, creates an nginx
          virtualHost with TLS (ACME) proxying to Grafana.
        '';
      };

      adminPasswordFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the Grafana admin password.
          In production, use config.sops.secrets.*.path.
        '';
      };

      secretKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the Grafana secret signing key.
          In production, use config.sops.secrets.*.path.
        '';
      };
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
              { targets = [ cfgVm.listenAddress ]; }
            ];
          }
          {
            job_name = "node-exporter";
            static_configs = exporterTargets config.services.prometheus.exporters.node;
          }
          {
            job_name = "grafana";
            static_configs = [
              { targets = [ gfAddr ]; }
            ];
          }
        ]
        ++ lib.optionals config.services.nginx.enable [
          {
            job_name = "nginx-exporter";
            static_configs = exporterTargets config.services.prometheus.exporters.nginx;
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

        # explicitly disable anonymous access
        "auth.anonymous" = {
          enable = false;
          # don't advertise our current version
          hide_version = true;
        };

        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;

          # configure public DNS name (if exposed publicly)
          domain = lib.mkIf (cfg.grafana.domain != null) cfg.grafana.domain;
          root_url = lib.mkIf (
            cfg.grafana.domain != null
          ) "https://${cfg.grafana.domain}/";

          # reject requests via ip addr, alt. hostnames, or bad proxy config
          enforce_domain = cfg.grafana.domain != null;

          # HTTPS-only browser
          cookie_secure = cfg.grafana.domain != null;
        };

        security = {
          admin_user = lib.mkDefault "admin";
          admin_password = "$__file{${gfCredsDir}/admin-password}";
          secret_key = "$__file{${gfCredsDir}/secret-key}";
          disable_gravatar = true;

          # NOTE(phlip9): can break OAuth/SAML/cross-site login
          cookie_samesite = "strict";

          # NOTE(phlip9): can break some plugins or HTML-heavy panels
          content_security_policy = true;

          # explicitly add datasources via `provision.datasources`
          data_source_proxy_whitelist = [
            cfgVm.listenAddress
          ];
        };

        users = {
          allow_sign_up = false;
          allow_org_create = false;
        };

        # just take a screenshot lol
        snapshots.enable = false;
      };

      # Provision VictoriaMetrics as a datasource using their Grafana plugin.
      provision.datasources = {
        settings = {
          apiVersion = 1;
          # Removing a datasource below will also remove it from Grafana after
          # we deploy.
          prune = true;
          datasources = [
            {
              name = "VictoriaMetrics (Plugin)";
              type = "victoriametrics-metrics-datasource";
              access = "proxy";
              uid = "victoriametrics";
              url = "http://${cfgVm.listenAddress}";
              isDefault = true;
              editable = false;
            }
            # TODO(phlip9): to use alerting via grafana (?) we might need to
            # configure a separate VM datasource but using type=prometheus:
            # <https://github.com/VictoriaMetrics/victoriametrics-datasource/issues/59#issuecomment-1541456768>
            # {
            #   name = "VictoriaMetrics (PromQL)";
            #   type = "prometheus";
            #   access = "proxy";
            #   uid = "victoriametrics-prometheus";
            #   url = "http://${cfgVm.listenAddress}";
            #   isDefault = false;
            #   editable = false;
            # }
          ];
        };
      };

      # Only allow installing grafana plugins via nix
      declarativePlugins = with pkgs.grafanaPlugins; [
        grafana-exploretraces-app
        grafana-lokiexplore-app
        grafana-metricsdrilldown-app
        grafana-pyroscope-app
        victoriametrics-metrics-datasource
      ];
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

        # Advertise HTTPS-only access for Grafana without committing all
        # subdomains to HSTS or browser preload lists.
        extraConfig = ''
          add_header Strict-Transport-Security "max-age=31536000" always;
        '';

        locations."/" = {
          proxyPass = "http://${gfAddr}";
          proxyWebsockets = true;
        };
      };
    };
  };
}
