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

  # vmalert + Alertmanager, see ./alerting.nix
  cfgAlerting = cfg.alerting;
  cfgAm = config.services.prometheus.alertmanager;
  amAddr = "${cfgAm.listenAddress}:${toString cfgAm.port}";

  # Pyroscope, see ./pyroscope.nix
  cfgProfiling = cfg.profiling;
  cfgPyroSrv = config.services.pyroscope.settings.server;
  pyroscopeAddr =
    "${cfgPyroSrv.http_listen_address}:" + toString cfgPyroSrv.http_listen_port;

  # Credentials directory for the grafana.service unit.
  gfCredsDir = "/run/credentials/grafana.service";

  # Host header Grafana expects, or "" if `[server] domain` is unset.
  gfHost = lib.optionalString (cfg.grafana.domain != null) cfg.grafana.domain;

  cfgGs = cfg.grafana.gitSync;
  gsIsLocal = cfgGs.enable && cfgGs.type == "local";
  # Only git repositories support the branch (+ PR) workflow.
  gsDefaultWorkflows = [
    "write"
  ]
  ++ lib.optional (cfgGs.type == "github") "branch";

  # Git Sync Repository resource, minus the secure token, which the setup
  # script injects at runtime. Field names from the Grafana source:
  # apps/provisioning/pkg/apis/provisioning/v0alpha1/types.go
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
      # Poll only. Grafana neither registers nor accepts a webhook.
      webhook.disabled = true;
    }
    // lib.optionalAttrs (cfgGs.type == "local") {
      local = { inherit (cfgGs.local) path; };
    };
  };
  gsRepoFile = pkgs.writeText "grafana-git-sync-repository.json" (
    builtins.toJSON gsRepo
  );

  # Idempotently create or update the Git Sync Repository via Grafana's
  # k8s-style API, authenticated as the Grafana admin, then queue a pull.
  # Secrets come from systemd credentials and only ever pass through files,
  # never argv.
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
          Public domain for Grafana. When set, creates an nginx
          virtualHost with TLS (ACME) proxying to Grafana.
        '';
      };

      logFilters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "sqlstore:debug" ];
        description = ''
          Per-logger levels (`<logger>:<level>`), joined into Grafana's
          `[log] filters`. A list so the module and tests can both add some.
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

      secretsManagerKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the key that encrypts data keys in
          Grafana's secrets manager (Git Sync tokens, other secure values).
          In production, use config.sops.secrets.*.path.
        '';
      };

      # Grafana Git Sync: sync dashboards + folders w/ git repo
      # See: doc/o11y/README.md
      gitSync = {
        enable = lib.mkEnableOption "Grafana Git Sync repository";

        name = lib.mkOption {
          type = lib.types.str;
          default = "dotfiles";
          description = ''
            Repository resource name (`metadata.name`). Renaming creates a
            new Repository. Delete the old one by hand.
          '';
        };

        title = lib.mkOption {
          type = lib.types.str;
          default = cfgGs.name;
          defaultText = lib.literalExpression "gitSync.name";
          description = ''
            Repository display name in the Grafana UI. W/ `target = "folder"`,
            also the root folder title.
          '';
        };

        type = lib.mkOption {
          type = lib.types.enum [
            "github"
            "local"
          ];
          description = ''
            Repository type. `github` commits to + polls a GitHub repo.
            `local` reads/writes a plain directory on this host (no git).
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
            description = ''
              Subdirectory in the repo for Grafana resources. Empty means
              the repo root.
            '';
          };

          webhook = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Let Grafana register and own a push + pull_request webhook on
              the GitHub repo (instant sync, PR integration). Needs a public
              https `root_url` and a PAT with Webhooks RW + Administration R.
              Deliveries hit an unauthenticated, HMAC-verified
              `.../repositories/<name>/webhook` endpoint. Polling stays on
              as a fallback. false: poll only.
            '';
          };
        };

        local.path = lib.mkOption {
          type = lib.types.str;
          example = "/var/lib/grafana-git-sync";
          description = ''
            Absolute directory for a `local` repository. Created owned by
            grafana and added to `[paths] permitted_provisioning_paths`.
          '';
        };

        tokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Path to a file containing a GitHub fine-grained PAT. Required
            for `type = "github"`. Stored in Grafana's secrets manager,
            re-sent (rotated) every time the setup unit runs.
            In production, use config.sops.secrets.*.path.
          '';
        };

        homeDashboard = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "overview";
          description = ''
            Uid of a synced dashboard to set as the org's home dashboard
            (org preference), on every setup run. Users w/o their own home
            dashboard preference land on it. Until it syncs, Grafana falls
            back to its default home. null: leave the preference alone.
          '';
        };

        intervalSeconds = lib.mkOption {
          type = lib.types.int;
          default = 3600;
          description = ''
            Seconds between polls for repo changes. W/ `github.webhook`,
            the webhook handles real-time updates and this is the fallback
            poll. The setup unit also triggers one pull on every start.
            Grafana's floor is `[provisioning] min_sync_interval` (10s).
            Grafana only checks this every `[provisioning] resync_interval`
            (60s), so shorter intervals also need a shorter resync.
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
            Allowed UI save workflows:
            - `write`: commit directly to the configured branch
            - `branch`: commit to a new branch (+ PR on GitHub)
            - (empty): read-only
          '';
        };

        target = lib.mkOption {
          type = lib.types.enum [
            "folder"
            "folderless"
          ];
          default = "folder";
          description = ''
            Sync target. Grafana rejects changes once a sync has run.

            - `folder`: everything under a root folder w/ uid `gitSync.name`
              and title `gitSync.title`. Git Sync creates that folder w/
              default role permissions (Editor: edit, Viewer: view), which its
              dashboards also inherit.

            - `folderless`: top level. Root dashboards get no role permissions,
              so only org Admins can access them; Editors, Viewers, and their
              service accounts get 403.

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

    # --- Grafana - visualization + dashboards --- #

    # Secrets loaded via systemd LoadCredential, referenced with
    # Grafana's $__file{path} provider.

    services.phlip9-o11y.server.grafana.logFilters = [
      # Silence these warnings
      "search-manifest-watcher:error"
    ];

    system.checks = [ gfPluginsCheck ];

    services.grafana = {
      enable = true;
      # patched so Git Sync isn't blocked by GitHub
      package = phlipPkgsNixos.grafana;
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
          ]
          ++ lib.optional cfgAlerting.enable amAddr
          # Profiles Drilldown, mcp-grafana, and profilecli query Pyroscope
          # through `/api/datasources/proxy/uid/pyroscope/...`, not
          # `/api/ds/query`, so they need this.
          ++ lib.optional cfgProfiling.enable pyroscopeAddr;
        };

        # The secrets manager encrypts secure values (ex: Git Sync tokens)
        # w/ data keys, which are encrypted by the current KMS provider.
        # The default `secret_key.v1` provider uses a PUBLIC key from
        # `conf/defaults.ini` and does NOT fall back to
        # `[security] secret_key`. Grafana loads every
        # `[secrets_manager.encryption.secret_key.*]` section as a separate
        # provider, so adding `v2` and switching `encryption_provider` is the
        # supported rotation path: new data keys use our key while any data
        # keys created under `v1` stay readable.
        # See: pkg/registry/apis/secret/encryption/kmsproviders/kmsproviders.go
        secrets_manager.encryption_provider = "secret_key.v2";
        "secrets_manager.encryption.secret_key.v2".secret_key =
          "$__file{${gfCredsDir}/secrets-manager-key}";

        users = {
          allow_sign_up = false;
          allow_org_create = false;
        };

        # just take a screenshot lol
        snapshots.enable = false;

        # Deprecated migration of Azure/SigV4-auth Prometheus datasources,
        # which we don't use. It needs the core `prometheus` plugin and logs
        # an error on every start w/o it.
        feature_toggles.prometheusTypeMigration = false;

        log.filters = lib.concatStringsSep " " cfg.grafana.logFilters;
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
          ]
          # Browse active alerts + manage silences in Grafana's alerting
          # UI. Alertmanager's own config and routes show up read-only.
          ++ lib.optional cfgAlerting.enable {
            name = "Alertmanager";
            type = "alertmanager";
            access = "proxy";
            uid = "alertmanager";
            url = "http://${amAddr}";
            editable = false;
            jsonData = {
              implementation = "prometheus";
              # Grafana-managed alert rules: none, keep them in Grafana.
              handleGrafanaManagedAlerts = false;
            };
          }
          # Flame graphs in panels + Explore, and the Profiles Drilldown app.
          ++ lib.optional cfgProfiling.enable {
            name = "Pyroscope";
            type = "grafana-pyroscope-datasource";
            access = "proxy";
            uid = "pyroscope";
            url = "http://${pyroscopeAddr}";
            # VM stays the default datasource.
            isDefault = false;
            editable = false;
            # Floor for the step of profile-derived time series queries
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
          # Grafana 13 dropped this from core
          phlipPkgsNixos.grafana-canvas-panel
        ]
        # Grafana 13.2 dropped this from core
        ++ lib.optionals cfgProfiling.enable [
          phlipPkgsNixos.grafana-pyroscope-datasource
        ];
    };

    # Inject Grafana secrets via systemd LoadCredential. The
    # grafana.service reads them at runtime from
    # /run/credentials/grafana.service/<name> via $__file{}.
    systemd.services.grafana.serviceConfig.LoadCredential = [
      "admin-password:${cfg.grafana.adminPasswordFile}"
      "secret-key:${cfg.grafana.secretKeyFile}"
      "secrets-manager-key:${cfg.grafana.secretsManagerKeyFile}"
    ];

    # --- Grafana Git Sync - dashboards <-> git repo --- #

    # Repository resources can't be file-provisioned, so a oneshot unit
    # creates/updates ours through the API after Grafana starts, then pulls.
    assertions = lib.optionals cfgGs.enable [
      {
        assertion = cfgGs.type == "github" -> cfgGs.tokenFile != null;
        message = "phlip9-o11y: gitSync.tokenFile is required for github";
      }
      {
        # Grafana rejects the branch workflow on non-git repositories.
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

    # A local repository must live under a permitted path. This replaces
    # Grafana's default (dev-only) list.
    services.grafana.settings.paths.permitted_provisioning_paths =
      lib.mkIf gsIsLocal cfgGs.local.path;
    systemd.tmpfiles.rules = lib.optional gsIsLocal (
      "d ${cfgGs.local.path} 0750 grafana grafana - -"
    );

    systemd.services.grafana-git-sync-setup = lib.mkIf cfgGs.enable {
      description = "Grafana Git Sync repository setup";
      # Re-run on every Grafana start, so each start queues a pull.
      # WantedBy= pulls us into grafana.service start job
      # PartOf= propagates stops + restarts (incl. Restart= crash recovery)
      wantedBy = [ "grafana.service" ];
      partOf = [ "grafana.service" ];
      after = [ "grafana.service" ];
      requires = [ "grafana.service" ];

      environment = {
        GRAFANA_URL = "http://${gfAddr}";
        # With `[server] enforce_domain`, Grafana 301-redirects any request
        # whose Host header (port ignored) doesn't match `[server] domain`.
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
        # Room for all the waits in the setup script: 2x ~1 min, 2x ~1 min.
        TimeoutStartSec = "4min";
        LoadCredential = [
          "admin-password:${cfg.grafana.adminPasswordFile}"
        ]
        ++ lib.optional (cfgGs.tokenFile != null) "token:${cfgGs.tokenFile}";
        DynamicUser = true;

        # Hardening. Only needs to talk to Grafana on localhost.
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

    # --- nginx - TLS termination + reverse proxy to Grafana --- #

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
