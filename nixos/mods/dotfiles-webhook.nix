# systemd unit for dotfiles-webhook GitHub webhook sync service.
# See: ../../pkgs/dotfiles-webhook/main.go
{
  config,
  lib,
  pkgs,
  phlipPkgs,
  ...
}:

let
  cfg = config.services.dotfiles-webhook;
  secrets = lib.attrByPath [ "sops" "secrets" ] { } config;
in
{
  options.services.dotfiles-webhook = {
    enable = lib.mkEnableOption "dotfiles webhook sync service";

    package = lib.mkOption {
      type = lib.types.package;
      default = phlipPkgs.dotfiles-webhook;
      description = "dotfiles-webhook package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8673;
      description = "TCP port to listen on.";
    };

    repo = lib.mkOption {
      type = lib.types.str;
      default = "/home/phlip9/dev/dotfiles";
      description = "Repository working tree to sync.";
    };

    remote = lib.mkOption {
      type = lib.types.str;
      default = "upstream";
      description = "Git remote to fetch from.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "master";
      description = "Git branch to reset to.";
    };

    quietMs = lib.mkOption {
      type = lib.types.int;
      default = 500;
      description = "Debounce window in milliseconds.";
    };

    maxBackoffMs = lib.mkOption {
      type = lib.types.int;
      default = 900000; # 15 min
      description = "Maximum initial-sync backoff in milliseconds.";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      default = "dotfiles-github-webhook-secret";
      description = "SOPS secret carrying the GitHub webhook secret.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "phlip9";
      description = "User account for the service.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for dotfiles-webhook.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasAttr cfg.secretName secrets;
        message = ''
          services.dotfiles-webhook.secretName="${cfg.secretName}" is not
          defined in config.sops.secrets.
        '';
      }
    ];

    systemd.services.dotfiles-webhook = {
      description = "dotfiles GitHub webhook sync";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.gitMinimal ];

      environment = {
        PORT = builtins.toString cfg.port;
        REPO = cfg.repo;
        REMOTE = cfg.remote;
        BRANCH = cfg.branch;
        QUIET_MS = builtins.toString cfg.quietMs;
        MAX_BACKOFF_MS = builtins.toString cfg.maxBackoffMs;
        GITHUB_WEBHOOK_SECRET_PATH = "%d/${cfg.secretName}";
      }
      // cfg.extraEnvironment;

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/dotfiles-webhook";
        User = cfg.user;
        WorkingDirectory = cfg.repo;
        ConditionPathExists = cfg.repo;
        Restart = "on-failure";
        RestartSec = 5;

        LoadCredential = [
          "${cfg.secretName}:${config.sops.secrets.${cfg.secretName}.path}"
        ];

        # Hardening
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = "read-only";
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "full";
        ReadWritePaths = [ cfg.repo ];
        RestrictSUIDSGID = true;
      };
    };
  };
}
