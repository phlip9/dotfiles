# Metrics observability module.
#
# Components:
# - VictoriaMetrics (metrics storage + scraper)
# - Grafana (visualization + dashboards)
# - prometheus-node-exporter (system metrics)
# - prometheus-nginx-exporter (nginx metrics, if nginx is enabled)
# - nginx virtualHost for Grafana (if grafana.domain is set)
# - Grafana Git Sync: bidirectional dashboard sync w/ a git repo (if
#   grafana.gitSync.enable is set)
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

  cfgNixbot = config.services.nixbot;

  exporterAddr = exporter: "${exporter.listenAddress}:${toString exporter.port}";
  exporterTargets = exporter: [
    { targets = [ (exporterAddr exporter) ]; }
  ];

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
    # Inputs, from the unit environment:
    # - GRAFANA_URL: base URL, ex: http://127.0.0.1:3000
    # - GRAFANA_HOST: Host header to send, or "" for none
    # - GRAFANA_ADMIN_USER: admin login
    # - REPO_NAME: Repository metadata.name
    # - REPO_MANIFEST: Repository JSON file, w/o secure values
    text = ''
      base_url=$GRAFANA_URL
      api_url="$base_url/apis/provisioning.grafana.app/v0alpha1"
      repos_url="$api_url/namespaces/default/repositories"
      host=$GRAFANA_HOST
      admin_user=$GRAFANA_ADMIN_USER
      name=$REPO_NAME
      manifest=$REPO_MANIFEST
      creds=$CREDENTIALS_DIRECTORY

      umask 077
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT

      # Basic auth header for the Grafana admin. Grafana trims whitespace
      # from `$__file{}` secrets, so trim here too.
      jq --null-input --raw-output \
        --arg user "$admin_user" \
        --rawfile password "$creds/admin-password" \
        '"Authorization: Basic " + ("\($user):\($password | trim)" | @base64)' \
        > "$tmp/auth-header"

      # api METHOD URL [BODY_FILE]
      #
      # Send an authenticated request to Grafana. Prints the HTTP status
      # ("000" if the connection failed). Response body goes to $tmp/resp.
      api() {
        local method=$1 url=$2 body=''${3:-}
        local args=(
          --silent --show-error
          --request "$method"
          --header @"$tmp/auth-header"
          --output "$tmp/resp"
          --write-out '%{http_code}'
        )
        if [[ -n $host ]]; then
          args+=(--header "Host: $host")
        fi
        if [[ -n $body ]]; then
          args+=(--header "Content-Type: application/json")
          args+=(--data-binary @"$body")
        fi
        rm -f "$tmp/resp"
        curl "''${args[@]}" "$url" || true
      }

      # die_http WHAT STATUS
      #
      # Log a failed request w/ its response body, then exit non-zero.
      die_http() {
        echo "error: $1: HTTP $2" >&2
        if [[ -f $tmp/resp ]]; then
          cat "$tmp/resp" >&2
          echo >&2
        fi
        exit 1
      }

      # wait_for_200 URL
      #
      # Poll until GET URL returns 200, for up to ~5 min. grafana.service is
      # Type=simple, so it may still be starting (DB migrations, slow under
      # load) or not have registered its k8s-style APIs yet.
      wait_for_200() {
        local status=000
        for _ in $(seq 150); do
          status=$(api GET "$1" 2>/dev/null)
          if [[ $status == 200 ]]; then
            return 0
          fi
          sleep 2
        done
        die_http "timed out waiting for GET $1" "$status"
      }

      echo "waiting for grafana at $base_url"
      wait_for_200 "$base_url/api/health"
      wait_for_200 "$api_url"

      # Request body: the static manifest + the token credential (if any).
      # jq reads the token from the file, so it never hits the nix store or
      # argv.
      if [[ -e $creds/token ]]; then
        jq --rawfile token "$creds/token" '
          ($token | trim) as $token
          | if $token == "" then error("token credential is empty") end
          | .secure.token.create = $token
        ' "$manifest" > "$tmp/body.json"
      else
        cp "$manifest" "$tmp/body.json"
      fi

      # Create or replace the Repository. Re-sending the token on every run
      # makes token rotation a restart: Grafana swaps in a new secure value
      # and deletes the old one. The PUT omits metadata.resourceVersion, an
      # unconditional update (Grafana's generic registry strategy sets
      # AllowUnconditionalUpdate). Status is preserved server-side.
      status=$(api GET "$repos_url/$name")
      case $status in
        404)
          status=$(api POST "$repos_url" "$tmp/body.json")
          [[ $status == 2?? ]] || die_http "create repository $name" "$status"
          echo "created repository $name"
          ;;
        200)
          status=$(api PUT "$repos_url/$name" "$tmp/body.json")
          [[ $status == 2?? ]] || die_http "update repository $name" "$status"
          echo "updated repository $name"
          ;;
        *)
          die_http "get repository $name" "$status"
          ;;
      esac

      # wait_for_repo_ready
      #
      # Poll until the controller has reconciled the current spec and the
      # repository is healthy, for up to ~3 min. Jobs need a healthy
      # repository. After an update, the stored health is stale until the
      # controller observes the new generation and re-runs its health check.
      wait_for_repo_ready() {
        local status=000
        for _ in $(seq 90); do
          status=$(api GET "$repos_url/$name")
          if [[ $status == 200 ]] && jq -e '
            .metadata.generation == .status.observedGeneration
            and .status.health.healthy == true
          ' "$tmp/resp" > /dev/null; then
            return 0
          fi
          sleep 2
        done
        if [[ $status != 200 ]]; then
          die_http "get repository $name" "$status"
        fi
        echo "error: timed out waiting for repository $name to turn healthy" >&2
        jq -c '
          {generation: .metadata.generation}
          + (.status | {observedGeneration})
          + (.status.health | {healthy, error, message})
        ' "$tmp/resp" >&2
        exit 1
      }

      # Grafana never syncs a repository on startup. Its controller only pulls
      # once `intervalSeconds` passed since the last sync, the spec changed,
      # or the repository recovered from unhealthy. A webhook only covers
      # pushes while Grafana runs, so a push made while Grafana was down would
      # wait up to a full poll interval. Instead, queue one incremental pull
      # (a no-op if the branch didn't move) on every start.
      # See: pkg/registry/apis/provisioning/controller/repository.go
      echo "waiting for repository $name to turn healthy"
      wait_for_repo_ready
      echo '{"action":"pull","pull":{"incremental":true}}' > "$tmp/pull.json"

      # A repository has at most one sync job, named `<name>-sync`, so this
      # fails w/ 409 AlreadyExists while another is queued or running, ex: the
      # controller's full sync after a spec change (incl. every token
      # re-send). Retry until ours is queued, for up to ~3 min.
      for _ in $(seq 90); do
        status=$(api POST "$repos_url/$name/jobs" "$tmp/pull.json")
        if [[ $status != 409 ]] \
          || ! jq -e '.reason == "AlreadyExists"' "$tmp/resp" > /dev/null; then
          break
        fi
        sleep 2
      done
      if [[ $status != 2?? ]]; then
        die_http "trigger pull job for repository $name" "$status"
      fi
      echo "triggered pull job for repository $name"
    '';
  };
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

      secretsManagerKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the key that encrypts data keys in
          Grafana's secrets manager (Git Sync tokens, other secure values).
          In production, use config.sops.secrets.*.path.
        '';
      };

      # Grafana Git Sync: bidirectional sync of dashboards + folders w/ a git
      # repository. Declares a single Repository resource.
      # See: doc/o11y/README.md
      gitSync = {
        enable = lib.mkEnableOption "Grafana Git Sync repository";

        name = lib.mkOption {
          type = lib.types.str;
          default = "dotfiles";
          description = ''
            Repository resource name (`metadata.name`). Renaming creates a
            new Repository; delete the old one by hand (which also deletes
            the dashboards it synced).
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
              Let Grafana register (and own) a push + pull_request webhook
              on the GitHub repo, for instant sync and PR integration.
              Grafana only registers it when `[server] root_url` is a
              public https URL; polling stays on as a fallback either way.
              Requires the PAT to have Webhooks: Read and write (repo
              admin) and Administration: Read. Deliveries go to the
              unauthenticated, HMAC-verified
              `/apis/provisioning.grafana.app/.../repositories/<name>/webhook`
              endpoint. false: poll only.
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

        intervalSeconds = lib.mkOption {
          type = lib.types.int;
          default = 60;
          description = ''
            Seconds between polls for repo changes. W/ `github.webhook`,
            the webhook handles real-time updates and this is the fallback
            poll. The setup unit also triggers one pull on every start.
            Grafana's floor is `[provisioning] min_sync_interval` (10s).
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
            Allowed UI save workflows. `write`: commit directly to the
            configured branch. `branch`: commit to a new branch (+ PR on
            GitHub). Empty: read-only.
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

            `folder`: everything under a root folder w/ uid `gitSync.name`
            and title `gitSync.title`; subdirs become subfolders. Git Sync
            creates that folder w/ default role permissions (Editor: edit,
            Viewer: view), which its dashboards inherit.

            `folderless`: top level; subdirs become folders. Root dashboards
            get no role permissions, so only org Admins can access them;
            Editors, Viewers, and their service accounts get 403.

            See: pkg/registry/apis/provisioning/resources/folders.go
          '';
        };
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
      # niks3 listens on IPv6 loopback; VM defaults to IPv4-only dialing.
      extraOptions = [ "-enableTCP6" ];

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
          in
          {
            job_name = "nixbot";
            scheme = if useTLS then "https" else "http";
            # VM uses server_name for both TLS verification/SNI and HTTP Host.
            tls_config.server_name = cfgNixbot.domain;
            static_configs = [
              { targets = [ "127.0.0.1:${if useTLS then "443" else "80"}" ]; }
            ];
          }
        )
        ++ lib.optional config.services.niks3.enable ({
          job_name = "niks3";
          static_configs = [
            { targets = [ config.services.niks3.httpAddr ]; }
          ];
        });
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
    # nginx-exporter needs stub_status exposed on localhost.
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
        };

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
      "secrets-manager-key:${cfg.grafana.secretsManagerKeyFile}"
    ];

    # ===================================================================
    # Grafana Git Sync - dashboards <-> git repository
    # ===================================================================
    #
    # Repository resources can't be file-provisioned, so a oneshot unit
    # creates/updates ours through the API after Grafana starts, then pulls.
    assertions = lib.optionals cfgGs.enable [
      {
        assertion = cfgGs.type == "github" -> cfgGs.tokenFile != null;
        message = "phlip9-o11y: gitSync.tokenFile is required for github";
      }
      {
        # Grafana rejects the branch workflow on non-git repositories.
        # See: apps/provisioning/pkg/repository/validator.go
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
      # WantedBy= pulls us into each grafana.service start job (boot,
      # `systemctl start`). PartOf= propagates its stops + restarts (incl.
      # Restart= crash recovery), so we never stay active across two Grafana
      # processes.
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
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe gsSetup;
        # Room for all the waits in the setup script: 2x ~5 min, 2x ~3 min.
        TimeoutStartSec = "20min";
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
