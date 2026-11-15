# o11y collector: this host's metrics + profiles.
#
# Components:
# - prometheus-node-exporter (system metrics)
# - prometheus-nginx-exporter (nginx metrics, if nginx is enabled)
# - prometheus-postgres-exporter (postgres metrics, if postgres is enabled)
# - rbitcoin node metrics (if rbitcoin is enabled)
# - nixos-exporter (boots, generation, pending reboot): see ./nixos-exporter.nix
# - Alloy eBPF profiler: see ./alloy.nix
# - vmagent: scrapes the job list (`scrapeConfigs`) and remote-writes the
#   samples to VictoriaMetrics. Jobs for this host's exporters + services;
#   server components add their own self-scrape jobs.
#
# Sink: the local VictoriaMetrics over loopback, so the collector needs
# `server.enable` on the same host.
#
# See: doc/o11y/README.md
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.phlip9-o11y;
  cfgC = cfg.collector;

  inherit (import ./lib.nix { inherit config; })
    exporterTargets
    hostTargets
    ;

  cfgVm = config.services.victoriametrics;
  cfgExporters = config.services.prometheus.exporters;
  cfgNixbot = config.services.nixbot;

  # rbitcoin serves `/metrics` on its loopback health listener.
  cfgRbitcoin = config.services.rbitcoin;
  rbitcoinHealthAddr =
    let
      inherit (cfgRbitcoin.health) address port;
      host = if lib.hasInfix ":" address then "[${address}]" else address;
    in
    "${host}:${toString port}";

  # vmagent HTTP server: `/metrics`, `/targets`, push endpoints. No authn,
  # keep it on loopback.
  vmagentAddr = "127.0.0.1:8429";

  # Where vmagent sends this host's samples: the local VictoriaMetrics over
  # loopback, no auth.
  remoteWriteUrl = "http://${cfgVm.listenAddress}/api/v1/write";
in
{
  imports = [
    ./nixos-exporter.nix
    ./alloy.nix
  ];

  options.services.phlip9-o11y.collector = {
    enable = lib.mkEnableOption ''
      the o11y collector: exporters + scrape jobs for this host's services.
      Needs `server.enable` on this host (local sink)
    '';

    # Keep in sync: nixos/sauna/grafana/*.json select by these `job_name`s,
    # ex: overview "Services" tiles (`up{job=...}`), probes (`blackbox`),
    # annotations (`nixos-exporter`); nix-ci (`nixbot`, `niks3`);
    # victoriametrics + node-exporter-full pin their own job.
    scrapeConfigs = lib.mkOption {
      type = lib.types.attrsOf (pkgs.formats.yaml { }).type;
      default = { };
      internal = true;
      description = ''
        Prometheus `scrape_configs` entries for this host, keyed by
        `job_name`. Each module adds the jobs for the services it runs, w/
        `instance=<hostname>` targets (`hostTargets` in ./lib.nix). Rendered
        sorted by `job_name`, independent of module order.
      '';
    };
  };

  config = lib.mkIf cfgC.enable {
    # vmagent's only sink is the local VictoriaMetrics, see `remoteWriteUrl`.
    # TODO(phlip9): drop once the collector can push to a remote server.
    assertions = [
      {
        assertion = cfg.server.enable;
        message = ''
          phlip9-o11y: collector.enable needs server.enable on the same host
          (the collector's only sink is the local VictoriaMetrics).
        '';
      }
    ];

    # ===================================================================
    # vmagent - scrapes `scrapeConfigs`, remote-writes to VictoriaMetrics
    # ===================================================================
    services.vmagent = {
      enable = true;
      # Same binary as the server's VictoriaMetrics, not `pkgs.vmagent`
      package = cfgVm.package;
      remoteWrite.url = remoteWriteUrl;
      prometheusConfig.scrape_configs = lib.mapAttrsToList (
        job_name: job: { inherit job_name; } // job
      ) cfgC.scrapeConfigs;
      extraArgs = [
        "-httpListenAddr=${vmagentAddr}"
        # niks3 listens on IPv6 loopback; vmagent dials IPv4 only by default.
        "-enableTCP6"
        # Best-effort delivery: no on-disk spool while running. While the
        # remote is down or slow, blocks wait in an in-memory queue
        # (retried w/ backoff, 1s..1m). Once it's full, the scrapers drop
        # new samples (`vmagent_remotewrite_samples_dropped_total`) and
        # keep scraping: scrapes go through `PushDropSamplesOnFailure`, so
        # they never block and memory stays bounded.
        # `-remoteWrite.dropSamplesOnOverload` only applies to clients
        # pushing to vmagent: we have none. A clean stop still writes the
        # in-memory queue to `-remoteWrite.tmpDataPath` (CacheDirectory)
        # and sends it after the restart.
        "-remoteWrite.disableOnDiskQueue"
        # Caps the in-memory queue at 100 blocks (100x queues). A block is
        # one non-empty flush (`-remoteWrite.flushInterval`, 1s), or less
        # when a flush exceeds the per-block row/byte limits, so the time
        # it covers depends on the scrape load: ~1 block/s on a busy host.
        # Plenty for a VictoriaMetrics restart (<1s on sauna). The
        # default, 2x CPU threads, buffers 24x that on sauna. One sender
        # keeps up w/ one host's scrapes.
        "-remoteWrite.queues=1"
      ];
    };

    systemd.services.vmagent = {
      # Its remote write target is local: start (+ restart) after it's up,
      # not into a retry backoff.
      after = [ "victoriametrics.service" ];

      # Hardening. Only scrapes + writes on loopback. The nixpkgs module
      # only sets DynamicUser.
      serviceConfig = {
        CapabilityBoundingSet = [ "" ];
        DevicePolicy = "closed";
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = [ "any" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };

    # This host's exporters + services. Each job only exists if its service
    # runs on this host.
    services.phlip9-o11y.collector.scrapeConfigs = {
      vmagent.static_configs = hostTargets vmagentAddr;
      node-exporter = lib.mkIf cfgExporters.node.enable {
        static_configs = exporterTargets cfgExporters.node;
      };
      nginx-exporter = lib.mkIf cfgExporters.nginx.enable {
        static_configs = exporterTargets cfgExporters.nginx;
      };
      postgres-exporter = lib.mkIf cfgExporters.postgres.enable {
        static_configs = exporterTargets cfgExporters.postgres;
      };
      nixbot = lib.mkIf cfgNixbot.enable (
        let
          useTLS = config.services.nginx.virtualHosts.${cfgNixbot.domain}.forceSSL;
          port = if useTLS then "443" else "80";
        in
        {
          scheme = if useTLS then "https" else "http";
          # vmagent uses server_name for both TLS verification/SNI + Host.
          tls_config.server_name = cfgNixbot.domain;
          static_configs = hostTargets "127.0.0.1:${port}";
        }
      );
      niks3 = lib.mkIf config.services.niks3.enable {
        static_configs = hostTargets config.services.niks3.httpAddr;
      };
      rbitcoin = lib.mkIf (cfgRbitcoin.enable && cfgRbitcoin.metrics) {
        static_configs = hostTargets rbitcoinHealthAddr;
      };
    };

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
