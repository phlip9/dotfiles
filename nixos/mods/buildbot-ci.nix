# Buildbot CI module for phlip9/dotfiles
#
# Components:
# - buildbot-nix master + worker (CI coordination)
# - niks3 (S3-backed binary cache with Cloudflare R2)
# - oauth2-proxy (via buildbot-nix's fullyPrivate mode)
# - nginx (TLS termination, routing - configured by buildbot-nix)
#
# NOTE: The buildbot-nix and niks3 NixOS modules are imported in
# nixos/mods/default.nix.
#
# See: docs/buildbot-nix-ci.md
{
  config,
  lib,
  phlipPkgs,
  ...
}:

let
  cfg = config.services.phlip9-buildbot-ci;
in
{
  options.services.phlip9-buildbot-ci = {
    enable = lib.mkEnableOption "phlip9 buildbot CI";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "ci.phlip9.com";
      description = "Domain for the buildbot web UI.";
    };

    cacheDomain = lib.mkOption {
      type = lib.types.str;
      default = "cache.phlip9.com";
      description = "Domain for the binary cache (served by Cloudflare R2).";
    };

    github = {
      appId = lib.mkOption {
        type = lib.types.int;
        description = "GitHub App ID.";
      };

      oauthClientId = lib.mkOption {
        type = lib.types.str;
        description = "GitHub OAuth App Client ID (for oauth2-proxy via fullyPrivate).";
      };
    };

    cloudflare = {
      accountId = lib.mkOption {
        type = lib.types.str;
        description = "Cloudflare Account ID for R2 endpoint.";
      };

      bucket = lib.mkOption {
        type = lib.types.str;
        default = "phlip9-nix-cache";
        description = "R2 bucket name.";
      };
    };

    cache = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "Nix signing public key for the cache.";
        example = "cache.phlip9.com-1:ABC123...";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # =========================================================================
    # niks3 - S3-backed binary cache server
    # =========================================================================
    services.niks3 = {
      enable = true;
      httpAddr = "[::1]:5751";
      cacheUrl = "https://${cfg.cacheDomain}";

      s3 = {
        endpoint = "${cfg.cloudflare.accountId}.r2.cloudflarestorage.com";
        bucket = cfg.cloudflare.bucket;
        useSSL = true;
        accessKeyFile = config.sops.secrets.niks3-s3-access-key.path;
        secretKeyFile = config.sops.secrets.niks3-s3-secret-key.path;
      };

      apiTokenFile = config.sops.secrets.niks3-api-token.path;
      signKeyFiles = [ config.sops.secrets.niks3-signing-key.path ];

      # Garbage collection
      gc = {
        enable = true;
        olderThan = "720h"; # 30 days
        schedule = "daily";
      };
    };

    # =========================================================================
    # buildbot-nix master
    # =========================================================================
    services.buildbot-nix.master = {
      enable = true;
      domain = cfg.domain;
      workersFile = config.sops.secrets.buildbot-nix-workers.path;

      buildSystems = [ "x86_64-linux" ];
      evalWorkerCount = 4; # tune for 6c/12t machine

      # Use fullyPrivate mode - puts oauth2-proxy in front of everything
      # This handles nginx config, oauth2-proxy, and webhook bypass automatically
      accessMode.fullyPrivate = {
        backend = "github";
        clientId = cfg.github.oauthClientId;
        clientSecretFile = config.sops.secrets.oauth2-proxy-client-secret.path;
        cookieSecretFile = config.sops.secrets.oauth2-proxy-cookie-secret.path;
        users = [
          "phlip9"
          "lexe-agent"
        ];
      };

      # httpBasicAuth password is required for fullyPrivate mode
      # (used internally between oauth2-proxy and buildbot)
      httpBasicAuthPasswordFile =
        config.sops.secrets.buildbot-http-basic-auth-password.path;

      github = {
        enable = true;
        appId = cfg.github.appId;
        appSecretKeyFile = config.sops.secrets.buildbot-github-app-secret-key.path;
        webhookSecretFile = config.sops.secrets.buildbot-github-webhook-secret.path;

        # Only build repos with this topic
        topic = "buildbot-phlip9";
        # Also allow specific users
        userAllowlist = [ "phlip9" ];
      };

      admins = [ "phlip9" ];
      outputsPath = "/var/www/buildbot/nix-outputs/";

      # niks3 integration for cache uploads
      niks3 = {
        enable = true;
        serverUrl = "http://[::1]:5751";
        authTokenFile = config.sops.secrets.niks3-api-token.path;
        package = phlipPkgs.niks3;
      };
    };

    # =========================================================================
    # buildbot-nix worker
    # =========================================================================
    services.buildbot-nix.worker = {
      enable = true;
      workerPasswordFile = config.sops.secrets.buildbot-nix-worker-password.path;
      # workers = 0 means use all CPU cores
      # With 6c/12t, reserving some for master/eval
      workers = 10;
    };

    # =========================================================================
    # nginx - TLS termination (buildbot-nix configures the virtualHost)
    # =========================================================================
    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = true;
      enableACME = true;

      # Remap webhook path: external /webhooks/github-buildbot-ci -> internal
      # buildbot-nix's oauth2-proxy already has skip-auth-route for /change_hook
      locations."/webhooks/github-buildbot-ci" = {
        proxyPass = "http://[::1]:${toString config.services.buildbot-nix.master.accessMode.fullyPrivate.port}/change_hook/github";
        extraConfig = ''
          proxy_connect_timeout 120s;
          proxy_send_timeout 120s;
          proxy_read_timeout 120s;
        '';
      };
    };

    # =========================================================================
    # Secrets
    # =========================================================================
    sops.secrets = {
      # niks3 / Cloudflare R2 (S3-compatible store)
      niks3-s3-access-key = { };
      niks3-s3-secret-key = { };
      niks3-api-token = { };
      niks3-signing-key = { };

      # buildbot
      buildbot-nix-workers = { };
      buildbot-nix-worker-password.owner = "buildbot-worker";
      buildbot-github-webhook-secret = { };
      buildbot-github-app-secret-key = { };
      buildbot-http-basic-auth-password = { };

      # oauth2-proxy (via buildbot-nix fullyPrivate)
      oauth2-proxy-client-secret = { };
      oauth2-proxy-cookie-secret = { };
    };

    # =========================================================================
    # Use our cache for nix builds on this machine
    # =========================================================================
    nix.settings = {
      extra-substituters = [ "https://${cfg.cacheDomain}" ];
      extra-trusted-public-keys = [ cfg.cache.publicKey ];
    };
  };
}
