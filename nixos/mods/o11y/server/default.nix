# o11y server: metrics storage + query.
#
# Components:
# - VictoriaMetrics (metrics storage + scraper)
# - prometheus-blackbox-exporter (HTTPS probes of `probes`, if any)
# - Grafana (visualization + dashboards): see ./grafana.nix
# - Alerting (vmalert + Alertmanager): see ./alerting.nix
# - Profiling (Pyroscope): see ./pyroscope.nix
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

  cfgNixbot = config.services.nixbot;

  # vmalert + Alertmanager, see ./alerting.nix
  cfgAlerting = cfg.alerting;
  vmalertAddr = config.services.vmalert.instances."".settings.httpListenAddr;
  cfgAm = config.services.prometheus.alertmanager;
  amAddr = "${cfgAm.listenAddress}:${toString cfgAm.port}";

  # Pyroscope + Alloy, see ./pyroscope.nix + ../collector/alloy.nix
  cfgProfiling = cfg.profiling;
  cfgPyroSrv = config.services.pyroscope.settings.server;
  pyroscopeAddr =
    "${cfgPyroSrv.http_listen_address}:" + toString cfgPyroSrv.http_listen_port;

  # rbitcoin serves `/metrics` on its loopback health listener.
  cfgRbitcoin = config.services.rbitcoin;
  rbitcoinHealthAddr =
    let
      inherit (cfgRbitcoin.health) address port;
      host = if lib.hasInfix ":" address then "[${address}]" else address;
    in
    "${host}:${toString port}";

  exporterAddr = exporter: "${exporter.listenAddress}:${toString exporter.port}";
  cfgBlackbox = config.services.prometheus.exporters.blackbox;

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
  exporterTargets = exporter: hostTargets (exporterAddr exporter);
in
{
  imports = [
    ./grafana.nix
    ./alerting.nix
    ./pyroscope.nix
  ];

  options.services.phlip9-o11y = {
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
    # VictoriaMetrics - metrics storage + scraper
    # ===================================================================
    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:8428";
      retentionPeriod = cfg.retentionPeriod;
      # niks3 listens on IPv6 loopback; VM defaults to IPv4-only dialing.
      extraOptions = [ "-enableTCP6" ];

      prometheusConfig = {
        # Keep in sync: nixos/sauna/grafana/*.json select by these
        # `job_name`s, ex: overview "Services" tiles (`up{job=...}`), probes
        # (`blackbox`), annotations (`nixos-exporter`); nix-ci (`nixbot`,
        # `niks3`); victoriametrics + node-exporter-full pin their own job.
        scrape_configs = [
          {
            job_name = "victoriametrics";
            static_configs = hostTargets cfgVm.listenAddress;
          }
        ]
        ++ lib.optional config.services.prometheus.exporters.node.enable {
          job_name = "node-exporter";
          static_configs = exporterTargets config.services.prometheus.exporters.node;
        }
        ++ [
          {
            job_name = "nixos-exporter";
            static_configs = hostTargets cfg.nixosExporter.listenAddress;
          }
        ]
        ++ lib.optional cfgGf.enable {
          job_name = "grafana";
          static_configs = hostTargets gfAddr;
        }
        ++ lib.optional config.services.prometheus.exporters.nginx.enable ({
          job_name = "nginx-exporter";
          static_configs = exporterTargets config.services.prometheus.exporters.nginx;
        })
        ++ lib.optional config.services.prometheus.exporters.postgres.enable ({
          job_name = "postgres-exporter";
          static_configs = exporterTargets config.services.prometheus.exporters.postgres;
        })
        ++ lib.optional cfgNixbot.enable (
          let
            useTLS = config.services.nginx.virtualHosts.${cfgNixbot.domain}.forceSSL;
            port = if useTLS then "443" else "80";
          in
          {
            job_name = "nixbot";
            scheme = if useTLS then "https" else "http";
            # VM uses server_name for both TLS verification/SNI and HTTP Host.
            tls_config.server_name = cfgNixbot.domain;
            static_configs = hostTargets "127.0.0.1:${port}";
          }
        )
        ++ lib.optional config.services.niks3.enable ({
          job_name = "niks3";
          static_configs = hostTargets config.services.niks3.httpAddr;
        })
        ++ lib.optional (cfgRbitcoin.enable && cfgRbitcoin.metrics) ({
          job_name = "rbitcoin";
          static_configs = hostTargets rbitcoinHealthAddr;
        })
        # Probe each URL through blackbox_exporter's `/probe?target=<url>`,
        # labeled `instance=<url>`, not the hostname: the probe alerts name
        # the URL.
        ++ lib.optional (cfg.probes != [ ]) {
          job_name = "blackbox";
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
        }
        ++ lib.optionals cfgAlerting.enable [
          {
            job_name = "vmalert";
            static_configs = hostTargets vmalertAddr;
          }
          {
            job_name = "alertmanager";
            static_configs = hostTargets amAddr;
          }
        ]
        ++ lib.optional cfgProfiling.enable {
          job_name = "pyroscope";
          static_configs = hostTargets pyroscopeAddr;
        }
        ++ lib.optional (cfgProfiling.enable && cfgProfiling.collector.enable) {
          job_name = "alloy";
          static_configs = hostTargets cfgProfiling.collector.listenAddress;
        };
      };
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
  };
}
