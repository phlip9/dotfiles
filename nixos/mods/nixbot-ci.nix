# nixbot CI module for phlip9/dotfiles (and more...)
#
# Components:
# - nixbot CI
# - niks3 (S3-backed binary cache with Cloudflare R2)
# - nginx (configured by nixbot)
#
# NOTE: The nixbot and niks3 NixOS modules are imported in
# nixos/mods/default.nix.
#
# See: doc/nixbot-ci.md
{
  config,
  lib,
  phlipPkgsNixos,
  ...
}:

let
  cfg = config.services.phlip9-nixbot-ci;
in
{
  options.services.phlip9-nixbot-ci = {
    enable = lib.mkEnableOption "phlip9 nixbot CI";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "ci.phlip9.com";
      description = "Domain for the nixbot web UI.";
    };

    admins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "github:phlip9" ];
      description = "List of nixbot admins.";
    };

    nginx = {
      enableACME = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Request ACME certs for CI domain.";
      };
    };

    github = {
      appId = lib.mkOption {
        type = lib.types.int;
        description = "GitHub App ID.";
      };

      oauthClientId = lib.mkOption {
        type = lib.types.str;
        description = "GitHub App OAuth2 Client ID.";
      };

      apiUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://api.github.com";
        description = "GitHub API base URL.";
      };

      userAllowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "phlip9" ];
        description = "GitHub users or organizations whose repos may build.";
      };

      topic = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          GitHub repo topic used to automatically add repos on first start.
          Otherwise repos must be added via the UI.
        '';
      };
    };

    cache = {
      url = lib.mkOption {
        type = lib.types.str;
        example = "https://cache.phlip9.com";
        description = "URL for the binary cache (served by Cloudflare R2).";
      };

      publicKey = lib.mkOption {
        type = lib.types.str;
        example = "cache.phlip9.com-1:ABC123...";
        description = "Nix signing public key for the cache.";
      };

      s3 = {
        endpoint = lib.mkOption {
          type = lib.types.str;
          example = "30faeb30dcb2a77a72fdc0948c99de62.r2.cloudflarestorage.com";
          description = "S3-compatible object store endpoint.";
        };

        bucket = lib.mkOption {
          type = lib.types.str;
          example = "phlip9-nix-cache";
          description = "R2 bucket name.";
        };

        useSSL = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Use TLS when connecting to the S3-compatible store.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # =========================================================================
    # nixbot CI
    # =========================================================================
    services.nixbot = {
      enable = true;
      inherit (cfg) admins domain;
      outputsPath = "/var/www/nixbot/nix-outputs/";

      # expose via NGINX
      nginx = {
        enable = true;
        inherit (cfg.nginx) enableACME;
      };

      buildSystems = [ "x86_64-linux" ];
      evalWorkerCount = 4; # tune for 6c/12t machine
      buildConcurrency = 10; # max concurrent builds

      github = {
        enable = true;
        inherit (cfg.github)
          appId
          apiUrl
          userAllowlist
          topic
          ;
        appSecretKeyFile = config.sops.secrets.nixbot-github-app-secret-key.path;
        webhookSecretFile = config.sops.secrets.nixbot-github-webhook-secret.path;
        oauthId = cfg.github.oauthClientId;
        oauthSecretFile = config.sops.secrets.nixbot-github-oauth-client-secret.path;

        oauthPrivateRepoScope = false; # enable if you need private repos
      };

      # niks3 integration for cache uploads
      niks3 = {
        enable = true;
        package = phlipPkgsNixos.niks3;
        serverUrl = "http://[::1]:5751";
        authTokenFile = config.sops.secrets.niks3-api-token.path;
      };
    };

    # =========================================================================
    # niks3 - S3-backed binary cache server
    # =========================================================================
    services.niks3 = {
      enable = true;
      httpAddr = "[::1]:5751";
      cacheUrl = cfg.cache.url;

      s3 = {
        inherit (cfg.cache.s3) endpoint bucket useSSL;
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

    # The upstream niks3 module orders only on `network.target`, so it starts
    # before DNS is up and crashes on boot ("dial tcp: lookup ...r2... no such
    # host") before `Restart=always` recovers it. Wait for `network-online`.
    systemd.services.niks3 = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };

    # =========================================================================
    # Secrets
    # =========================================================================
    sops.secrets = {
      # niks3 / Cloudflare R2 (S3-compatible store)
      niks3-s3-access-key.owner = "niks3";
      niks3-s3-secret-key.owner = "niks3";
      niks3-api-token.owner = "niks3";
      niks3-signing-key.owner = "niks3";

      # nixbot
      nixbot-github-app-secret-key = { };
      nixbot-github-oauth-client-secret = { };
      nixbot-github-webhook-secret = { };
    };
  };
}
