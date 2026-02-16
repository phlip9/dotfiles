# systemd socket + service for github-agent-authd token broker.
#
# See also:
#   - doc/github-agent-access/02-implementation.md
#   - nixos/tests/github-agent-authd.nix
#   - pkgs/github-agent-authd/main.go
#   - pkgs/github-agent-authd/default.nix
{
  config,
  lib,
  phlipPkgs,
  ...
}:

let
  cfg = config.services.github-agent-authd;
in
{
  options.services.github-agent-authd = {
    enable = lib.mkEnableOption "github-agent-authd token broker";

    package = lib.mkOption {
      type = lib.types.package;
      default = phlipPkgs.github-agent-authd;
      description = "github-agent-authd package to run.";
    };

    appId = lib.mkOption {
      type = lib.types.str;
      example = "123456";
      description = "GitHub App ID used to mint installation tokens.";
    };

    appKeyPath = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the GitHub App private key PEM.

        The module loads this file via systemd credentials, and the daemon
        reads it from `%d/app-key` inside `$CREDENTIALS_DIRECTORY`.
      '';
    };

    githubApiBase = lib.mkOption {
      type = lib.types.str;
      default = "https://api.github.com";
      description = "GitHub API base URL.";
    };

    installationCacheTtl = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = "Installation cache TTL duration.";
    };

    idleShutdownTimeout = lib.mkOption {
      type = lib.types.str;
      default = "30m";
      description = "Auto-shutdown the auth broker after being idle.";
    };

    socketGroup = lib.mkOption {
      type = lib.types.str;
      default = "github-agent";
      description = "Group allowed to mint access tokens via the unix socket.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.socketGroup} = { };

    systemd.sockets.github-agent-authd = {
      description = "GitHub agent auth broker socket";
      wantedBy = [ "sockets.target" ];

      socketConfig = {
        ListenStream = "/run/github-agent-authd/socket";
        SocketMode = "0660";
        SocketGroup = cfg.socketGroup;
        # Let systemd create the parent runtime directory for ListenStream.
        # Directory ownership is root:root, so keep it traversable and rely on
        # socket mode/group for actual access control.
        DirectoryMode = "0755";
        RemoveOnStop = true;
      };
    };

    systemd.services.github-agent-authd = {
      description = "GitHub agent auth broker";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "github-agent-authd.socket" ];

      environment = {
        GITHUB_API_BASE = cfg.githubApiBase;
        APP_ID = cfg.appId;
        APP_KEY_PATH = "%d/app-key";
        INSTALLATION_CACHE_TTL = cfg.installationCacheTtl;
        IDLE_SHUTDOWN_TIMEOUT = cfg.idleShutdownTimeout;
      };

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/github-agent-authd";
        LoadCredential = [ "app-key:${cfg.appKeyPath}" ];
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = "read-only";
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictSUIDSGID = true;
      };
    };
  };
}
