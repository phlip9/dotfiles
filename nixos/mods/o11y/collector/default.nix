# o11y collector: host exporters, vmagent scraper, Alloy profiler.
# Pushes to local server (loopback) or `remote` (HTTPS + basic auth).
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
    ingest
    ;

  cfgVm = config.services.victoriametrics;
  cfgExporters = config.services.prometheus.exporters;
  cfgNixbot = config.services.nixbot;

  cfgRbitcoin = config.services.rbitcoin;
  rbitcoinHealthAddr =
    let
      inherit (cfgRbitcoin.health) address port;
      host = if lib.hasInfix ":" address then "[${address}]" else address;
    in
    "${host}:${toString port}";

  # Loopback only: no auth on /metrics, /targets, push endpoints.
  vmagentAddr = "127.0.0.1:8429";

  cfgRemote = cfgC.remote;
  isLocal = cfgRemote == null;

  remoteWriteUrl =
    if isLocal then
      "http://${cfgVm.listenAddress}/api/v1/write"
    else
      "${cfgRemote.url}${ingest.metricsPath}";
in
{
  imports = [
    ./nixos-exporter.nix
    ./alloy.nix
  ];

  options.services.phlip9-o11y.collector = {
    enable = lib.mkEnableOption "o11y collector (exporters, vmagent, Alloy)";

    remote = lib.mkOption {
      default = null;
      description = ''
        Remote ingest target (`server.ingest`). Overrides local `server.enable`
        if both are set. Best-effort push (drops on failure/overflow); no
        network needed at startup.
      '';
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              # HTTPS only (basic auth).
              type = lib.types.strMatching "^https://[^?#]*[^/?#]$";
              example = "https://sauna.phlip9.com/o11y";
              description = ''
                Ingest base URL (`https://<vhost>/o11y`), no trailing slash.
              '';
            };

            username = lib.mkOption {
              type = lib.types.strMatching ingest.usernameRegex;
              default = config.networking.hostName;
              defaultText = lib.literalExpression "config.networking.hostName";
              description = ''
                Basic auth user in server's `htpasswdFile`. Server stamps
                metrics w/ `instance=<username>`; keep equal to
                `collector.profiling.hostLabel`.
              '';
            };

            passwordFile = lib.mkOption {
              type = lib.types.path;
              example = lib.literalExpression (
                "config.sops.secrets.o11y-ingest-password.path"
              );
              description = ''
                Basic auth password file (secret; trailing whitespace trimmed).
                Root-only ok: passed as systemd credential (restart vmagent +
                Alloy on change via sops `restartUnits`).
              '';
            };
          };
        }
      );
    };

    # Keep in sync w/ nixos/sauna/grafana/*.json (dashboards query by job_name).
    scrapeConfigs = lib.mkOption {
      type = lib.types.attrsOf (pkgs.formats.yaml { }).type;
      default = { };
      internal = true;
      description = ''
        Prometheus `scrape_configs` keyed by `job_name` (targets via
        `hostTargets` in ./lib.nix). Attrset ensures deterministic order.
      '';
    };
  };

  config = lib.mkIf cfgC.enable {
    assertions = [
      {
        assertion = cfg.server.enable || !isLocal;
        message = ''
          phlip9-o11y: collector.enable needs a sink: server.enable on the
          same host, or collector.remote.
        '';
      }
    ];

    # --- vmagent --- #

    services.vmagent = {
      enable = true;
      # Match server VM pkg, not pkgs.vmagent.
      package = cfgVm.package;
      remoteWrite = {
        url = remoteWriteUrl;
      }
      // lib.optionalAttrs (!isLocal) {
        basicAuthUsername = cfgRemote.username;
        # toString: prevent Nix from copying secret path into store.
        basicAuthPasswordFile = toString cfgRemote.passwordFile;
      };
      prometheusConfig.scrape_configs = lib.mapAttrsToList (
        job_name: job: { inherit job_name; } // job
      ) cfgC.scrapeConfigs;
      extraArgs = [
        "-httpListenAddr=${vmagentAddr}"
        # niks3 binds IPv6 loopback; vmagent defaults to IPv4 only.
        "-enableTCP6"
        # Best-effort: no disk spool while running; drops new samples when
        # in-memory queue fills (clean stop still flushes to CacheDirectory).
        "-remoteWrite.disableOnDiskQueue"
        # Caps in-memory queue at 100 blocks (100x queues, vs default 2*CPUs).
        # 1 sender suffices per host and covers <1s VM restarts.
        "-remoteWrite.queues=1"
      ];
    };

    systemd.services.vmagent = {
      # Local: start after VM to avoid initial backoff. Remote: skip
      # network-online.target; vmagent retries (<= 1m backoff).
      after = lib.mkIf isLocal [ "victoriametrics.service" ];

      # Hardening (nixpkgs module only sets DynamicUser).
      serviceConfig = {
        CapabilityBoundingSet = [ "" ];
        DevicePolicy = "closed";
        # Remote: allow any IP (resolved via DNS).
        IPAddressAllow = lib.mkIf isLocal [ "localhost" ];
        IPAddressDeny = lib.mkIf isLocal [ "any" ];
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
        ]
        # Remote DNS: cgo vmagent resolves via glibc NSS -> nscd unix socket.
        ++ lib.optional (!isLocal) "AF_UNIX";
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
          # Sets TLS SNI/verify + HTTP Host.
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

    # --- prometheus-node-exporter --- #

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9100;
      enabledCollectors = [
        "systemd"
        "processes"
      ];
    };

    # --- prometheus-nginx-exporter --- #

    services.prometheus.exporters.nginx = lib.mkIf config.services.nginx.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9113;
    };
    # Expose stub_status for nginx-exporter (loopback-bound below).
    services.nginx.statusPage = lib.mkIf config.services.nginx.enable true;

    # --- prometheus-postgres-exporter --- #

    services.prometheus.exporters.postgres =
      lib.mkIf config.services.postgresql.enable
        {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9187;
          runAsLocalSuperUser = true;
          # PG 17 moved checkpoints out of pg_stat_bgwriter. Keep in sync w/
          # nixos/sauna/grafana/postgres-overview.json ("Buffers").
          extraFlags = [ "--collector.stat_checkpointer" ];
        };

    # --- rbitcoin --- #

    # /metrics served on health listener.
    services.rbitcoin = lib.mkIf cfgRbitcoin.enable {
      health.enable = lib.mkDefault true;
      metrics = lib.mkDefault true;
    };

    # --- nginx stub_status --- #

    # Upstream binds stub_status to all interfaces, causing bot log spam
    # (already IP-allowlisted; loopback binding cuts noise).
    services.nginx.virtualHosts = lib.mkIf config.services.nginx.enable {
      localhost.listenAddresses = [
        "127.0.0.1"
        "[::1]"
      ];
    };
  };
}
