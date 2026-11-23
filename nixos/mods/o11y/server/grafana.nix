# o11y server: Grafana (visualization + dashboards).
#
# - Grafana w/ VictoriaMetrics, Alertmanager, Pyroscope datasources
# - Grafana Git Sync: dashboard sync w/ git repo
# - nginx virtualHost for Grafana (if grafana.domain is set)
#
# Grafana secrets are injected via systemd LoadCredential and read via
# `$__file{}` providers from sops-nix managed secret files.
#
# See: doc/o11y/README.md
{
  config,
  lib,
  phlipPkgs,
  phlipPkgsNixos,
  pkgs,
  ...
}:

let
  inherit (builtins) toString;

  cfg = config.services.phlip9-o11y.server;

  cfgVm = config.services.victoriametrics;
  cfgGf = config.services.grafana;
  cfgGfSrv = cfgGf.settings.server;
  gfAddr = "${cfgGfSrv.http_addr}:${toString cfgGfSrv.http_port}";

  inherit (import ../collector/lib.nix { inherit config; }) hostTargets;

  # Fail build if plugin's `grafanaDependency` excludes our Grafana version.
  gfPluginsCheck =
    let
      check = phlipPkgs.writeTypedPython3Bin "grafana-plugins-check" { } (
        builtins.readFile ./grafana-plugins-check.py
      );
    in
    pkgs.runCommand "grafana-plugins-check" { } ''
      ${lib.getExe check} ${
        lib.escapeShellArgs (
          [ cfgGf.package.version ] ++ map toString cfgGf.declarativePlugins
        )
      }
      touch $out
    '';

  cfgAlerting = cfg.alerting;
  cfgAm = config.services.prometheus.alertmanager;
  amAddr = "${cfgAm.listenAddress}:${toString cfgAm.port}";

  cfgProfiling = cfg.profiling;
  cfgPyroSrv = config.services.pyroscope.settings.server;
  pyroscopeAddr =
    "${cfgPyroSrv.http_listen_address}:" + toString cfgPyroSrv.http_listen_port;

  gfCredsDir = "/run/credentials/grafana.service";

  gfHost = lib.optionalString (cfg.grafana.domain != null) cfg.grafana.domain;

  cfgGs = cfg.grafana.gitSync;
  gsIsLocal = cfgGs.enable && cfgGs.type == "local";
  # Only git repos support the branch workflow.
  gsDefaultWorkflows = [
    "write"
  ]
  ++ lib.optional (cfgGs.type == "github") "branch";

  # Git Sync Repository manifest (token injected at runtime by setup script).
  # See: <grafana>/apps/provisioning/pkg/apis/provisioning/v0alpha1/types.go
  gsRepo = {
    apiVersion = "provisioning.grafana.app/v0alpha1";
    kind = "Repository";
    metadata = {
      inherit (cfgGs) name;
      namespace = "default";
    };
    spec = {
      inherit (cfgGs) title type workflows;
      sync = {
        enabled = true;
        inherit (cfgGs) target intervalSeconds;
      };
    }
    // lib.optionalAttrs (cfgGs.type == "github") {
      github = { inherit (cfgGs.github) url branch path; };
    }
    // lib.optionalAttrs (cfgGs.type == "github" && !cfgGs.github.webhook) {
      webhook.disabled = true;
    }
    // lib.optionalAttrs (cfgGs.type == "local") {
      local = { inherit (cfgGs.local) path; };
    };
  };
  gsRepoFile = pkgs.writeText "grafana-git-sync-repository.json" (
    builtins.toJSON gsRepo
  );

  # Idempotently upserts the Git Sync Repository via API and queues a pull.
  # Reads secrets from systemd credential files (never argv).
  gsSetup = pkgs.writeShellApplication {
    name = "grafana-git-sync-setup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = builtins.readFile ./grafana-git-sync-setup.sh;
  };
in
{
  options.services.phlip9-o11y.server = {
    grafana = {
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "grafana.phlip9.com";
        description = ''
          Public Grafana domain. Creates an nginx TLS (ACME) vhost when set.
        '';
      };

      logFilters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "sqlstore:debug" ];
        description = ''
          Per-logger `<logger>:<level>` filters joined into `[log] filters`
          (list so module and tests can both append).
        '';
      };

      adminPasswordFile = lib.mkOption {
        type = lib.types.path;
        description = "Grafana admin password file (secret).";
      };

      secretKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Grafana secret signing key file (secret).";
      };

      secretsManagerKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          KMS key file encrypting Grafana secrets manager data keys (Git Sync
          tokens, etc.; secret).
        '';
      };

      gitSync = {
        enable = lib.mkEnableOption "Grafana Git Sync repository";

        name = lib.mkOption {
          type = lib.types.str;
          default = "dotfiles";
          description = ''
            Repository `metadata.name`. Renaming creates a new Repository
            (delete the old one manually).
          '';
        };

        title = lib.mkOption {
          type = lib.types.str;
          default = cfgGs.name;
          defaultText = lib.literalExpression "gitSync.name";
          description = ''
            UI display name (also root folder title w/ `target = "folder"`).
          '';
        };

        type = lib.mkOption {
          type = lib.types.enum [
            "github"
            "local"
          ];
          description = ''
            `github` syncs a GitHub repo; `local` uses a plain dir (no git).
          '';
        };

        github = {
          url = lib.mkOption {
            type = lib.types.str;
            example = "https://github.com/phlip9/dotfiles";
            description = "GitHub repository URL.";
          };

          branch = lib.mkOption {
            type = lib.types.str;
            default = "master";
            description = "Branch to sync from and commit to.";
          };

          path = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "nixos/sauna/grafana";
            description = "Repo subdir for Grafana resources (empty = root).";
          };

          webhook = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Register a GitHub push/PR webhook (polling stays as fallback;
              false = poll only). Needs public HTTPS `root_url` and a PAT w/
              Webhooks RW + Administration R (HMAC-verified endpoint).
            '';
          };
        };

        local.path = lib.mkOption {
          type = lib.types.str;
          example = "/var/lib/grafana-git-sync";
          description = ''
            Absolute dir for a `local` repo (created grafana-owned and added
            to `[paths] permitted_provisioning_paths`).
          '';
        };

        tokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            GitHub fine-grained PAT file (secret; required for `github`).
            Rotated into Grafana's secrets manager on every setup run.
          '';
        };

        homeDashboard = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "overview";
          description = ''
            Synced dashboard uid set as org home dashboard on each setup run
            (falls back to default until synced; null leaves it untouched).
          '';
        };

        intervalSeconds = lib.mkOption {
          type = lib.types.int;
          default = 3600;
          description = ''
            Poll interval in seconds (fallback when `github.webhook` is on;
            setup unit also pulls on start). Floor is 10s (`min_sync_interval`);
            intervals < 60s also require lowering `resync_interval`.
          '';
        };

        workflows = lib.mkOption {
          type = lib.types.listOf (
            lib.types.enum [
              "write"
              "branch"
            ]
          );
          default = gsDefaultWorkflows;
          defaultText = lib.literalExpression ''
            [ "write" ] ++ lib.optional (gitSync.type == "github") "branch"
          '';
          description = ''
            Allowed UI save workflows (`write` commits to branch, `branch`
            opens a branch/PR on GitHub, empty = read-only).
          '';
        };

        target = lib.mkOption {
          type = lib.types.enum [
            "folder"
            "folderless"
          ];
          default = "folder";
          description = ''
            Sync target (immutable after first sync). `folder` puts resources
            under a root folder (`gitSync.name`/`title`) w/ default
            Editor/Viewer RBAC. `folderless` puts dashboards at root w/ no role
            permissions (non-Admins and their service accounts get 403).
            See: `<grafana>/pkg/registry/apis/provisioning/resources/folders.go`
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.phlip9-o11y.collector.scrapeConfigs.grafana = lib.mkIf cfgGf.enable {
      static_configs = hostTargets gfAddr;
    };

    # --- Grafana --- #

    services.phlip9-o11y.server.grafana.logFilters = [
      # Silence noisy watcher warnings.
      "search-manifest-watcher:error"
    ];

    system.checks = [ gfPluginsCheck ];

    services.grafana = {
      enable = true;
      package = phlipPkgsNixos.grafana;
      provision.enable = true;

      settings = {
        analytics.reporting_enabled = false;

        "auth.anonymous" = {
          enable = false;
          hide_version = true;
        };

        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;

          domain = lib.mkIf (cfg.grafana.domain != null) cfg.grafana.domain;
          root_url = lib.mkIf (
            cfg.grafana.domain != null
          ) "https://${cfg.grafana.domain}/";

          enforce_domain = cfg.grafana.domain != null;
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

          data_source_proxy_whitelist = [
            cfgVm.listenAddress
          ]
          ++ lib.optional cfgAlerting.enable amAddr
          # Needed by Profiles Drilldown, mcp-grafana, and profilecli
          # (`/api/datasources/proxy/uid/pyroscope/...`).
          ++ lib.optional cfgProfiling.enable pyroscopeAddr;
        };

        # Default `secret_key.v1` uses a public key from defaults.ini (not
        # `[security] secret_key`). Adding `v2` rotates new data keys to our
        # key while keeping any `v1`-encrypted keys readable.
        # See: pkg/registry/apis/secret/encryption/kmsproviders/kmsproviders.go
        secrets_manager.encryption_provider = "secret_key.v2";
        "secrets_manager.encryption.secret_key.v2".secret_key =
          "$__file{${gfCredsDir}/secrets-manager-key}";

        users = {
          allow_sign_up = false;
          allow_org_create = false;
        };

        snapshots.enable = false;

        # Deprecated Azure/SigV4 migration; logs an error on start without the
        # core `prometheus` plugin.
        feature_toggles.prometheusTypeMigration = false;

        log.filters = lib.concatStringsSep " " cfg.grafana.logFilters;
      };

      provision.datasources = {
        settings = {
          apiVersion = 1;
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
          ]
          ++ lib.optional cfgAlerting.enable {
            name = "Alertmanager";
            type = "alertmanager";
            access = "proxy";
            uid = "alertmanager";
            url = "http://${amAddr}";
            editable = false;
            jsonData = {
              implementation = "prometheus";
              # Alerts are managed in vmalert, not Grafana.
              handleGrafanaManagedAlerts = false;
            };
          }
          ++ lib.optional cfgProfiling.enable {
            name = "Pyroscope";
            type = "grafana-pyroscope-datasource";
            access = "proxy";
            uid = "pyroscope";
            url = "http://${pyroscopeAddr}";
            isDefault = false;
            editable = false;
            jsonData.minStep = "15s";
          };
        };
      };

      # Only allow installing grafana plugins via nix
      declarativePlugins =
        with pkgs.grafanaPlugins;
        [
          grafana-exploretraces-app
          grafana-lokiexplore-app
          grafana-metricsdrilldown-app
          grafana-pyroscope-app
          victoriametrics-metrics-datasource
          # Dropped from core in Grafana 13.
          phlipPkgsNixos.grafana-canvas-panel
        ]
        # Dropped from core in Grafana 13.2.
        ++ lib.optionals cfgProfiling.enable [
          phlipPkgsNixos.grafana-pyroscope-datasource
        ];
    };

    systemd.services.grafana.serviceConfig.LoadCredential = [
      "admin-password:${cfg.grafana.adminPasswordFile}"
      "secret-key:${cfg.grafana.secretKeyFile}"
      "secrets-manager-key:${cfg.grafana.secretsManagerKeyFile}"
    ];

    # --- Grafana Git Sync --- #

    # Repositories can't be file-provisioned; oneshot unit upserts + pulls.
    assertions = lib.optionals cfgGs.enable [
      {
        assertion = cfgGs.type == "github" -> cfgGs.tokenFile != null;
        message = "phlip9-o11y: gitSync.tokenFile is required for github";
      }
      {
        # Grafana rejects `branch` workflow on non-git repos.
        # See: `<grafana>/apps/provisioning/pkg/repository/validator.go`
        assertion = gsIsLocal -> !(lib.elem "branch" cfgGs.workflows);
        message = "phlip9-o11y: gitSync.workflows: local can't use branch";
      }
      {
        assertion = gsIsLocal -> lib.hasPrefix "/" cfgGs.local.path;
        message = "phlip9-o11y: gitSync.local.path must be absolute";
      }
      {
        assertion = cfgGs.intervalSeconds >= 10;
        message = "phlip9-o11y: gitSync.intervalSeconds must be >= 10";
      }
    ];

    # Replaces Grafana's dev-only default list so local repo paths are allowed.
    services.grafana.settings.paths.permitted_provisioning_paths =
      lib.mkIf gsIsLocal cfgGs.local.path;
    systemd.tmpfiles.rules = lib.optional gsIsLocal (
      "d ${cfgGs.local.path} 0750 grafana grafana - -"
    );

    systemd.services.grafana-git-sync-setup = lib.mkIf cfgGs.enable {
      description = "Grafana Git Sync repository setup";
      # Run on every Grafana start/restart (incl. crash recovery) to queue a
      # pull.
      wantedBy = [ "grafana.service" ];
      partOf = [ "grafana.service" ];
      after = [ "grafana.service" ];
      requires = [ "grafana.service" ];

      environment = {
        GRAFANA_URL = "http://${gfAddr}";
        # Needed w/ `enforce_domain` (else Grafana 301-redirects bad Host).
        GRAFANA_HOST = gfHost;
        GRAFANA_ADMIN_USER = cfgGf.settings.security.admin_user;
        REPO_NAME = cfgGs.name;
        REPO_MANIFEST = gsRepoFile;
        HOME_DASHBOARD = lib.optionalString (
          cfgGs.homeDashboard != null
        ) cfgGs.homeDashboard;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe gsSetup;
        # Covers setup script wait loops (4x ~1 min).
        TimeoutStartSec = "4min";
        LoadCredential = [
          "admin-password:${cfg.grafana.adminPasswordFile}"
        ]
        ++ lib.optional (cfgGs.tokenFile != null) "token:${cfgGs.tokenFile}";
        DynamicUser = true;

        # Hardening (only talks to localhost Grafana).
        CapabilityBoundingSet = [ "" ];
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = [ "any" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
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
          "AF_UNIX"
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

    # --- nginx --- #

    services.nginx.virtualHosts = lib.mkIf (cfg.grafana.domain != null) {
      ${cfg.grafana.domain} = {
        forceSSL = true;
        enableACME = true;

        # HSTS for Grafana only (no includeSubDomains or preload).
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
