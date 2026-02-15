# systemd unit for github-webhook GitHub webhook service.
# See: ../../pkgs/github-webhook/main.go
{
  config,
  lib,
  pkgs,
  phlipPkgs,
  ...
}:

let
  cfg = config.services.github-webhook;
  secrets = lib.attrByPath [ "sops" "secrets" ] { } config;

  # Convert NixOS config to JSON format expected by Go service.
  makeConfig =
    {
      port,
      repos,
    }:
    let
      mkRepo = repoFullName: repoCfg: {
        secret_path = "%d/${repoCfg.secretName}";
        branches = repoCfg.branches;
        command = repoCfg.command;
        working_dir = repoCfg.workingDir;
        quiet_ms = repoCfg.quietMs;
        run_on_startup = repoCfg.runOnStartup;
        timeout_ms = repoCfg.timeoutMs;
      };
    in
    {
      port = toString port;
      repos = lib.mapAttrs mkRepo repos;
    };

  configJson = builtins.toJSON (makeConfig {
    inherit (cfg) port repos;
  });

  configFile = pkgs.writeText "github-webhook-config.json" configJson;
in
{
  options.services.github-webhook = {
    enable = lib.mkEnableOption "GitHub webhook service";

    package = lib.mkOption {
      type = lib.types.package;
      default = phlipPkgs.github-webhook;
      description = "github-webhook package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8673;
      description = "TCP port to listen on.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User account for the service.";
    };

    repos = lib.mkOption {
      default = { };
      description = ''
        Repository configurations. The attribute name should be the full
        repository name (e.g., "phlip9/dotfiles").
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            secretName = lib.mkOption {
              type = lib.types.str;
              description = "SOPS secret name carrying the GitHub webhook secret.";
            };

            branches = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "master" ];
              description = "List of branch names to track.";
            };

            command = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Command to execute on webhook event.";
            };

            workingDir = lib.mkOption {
              type = lib.types.str;
              description = "Working directory for command execution.";
            };

            quietMs = lib.mkOption {
              type = lib.types.int;
              default = 500;
              description = "Debounce window in milliseconds.";
            };

            runOnStartup = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Run command once on service startup.";
            };

            timeoutMs = lib.mkOption {
              type = lib.types.int;
              default = 3600000; # 1 hour
              description = "Command timeout in milliseconds.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasAttr cfg.user config.users.users;
        message = ''
          services.github-webhook.user="${cfg.user}" is not defined in
          config.users.users.
        '';
      }
    ]
    ++ (lib.mapAttrsToList (repoId: repoCfg: {
      assertion = builtins.pathExists repoCfg.workingDir || true;
      message = ''
        services.github-webhook.repos.${repoId}.workingDir
        "${repoCfg.workingDir}" will be checked at runtime via systemd ConditionPathExists.
      '';
    }) cfg.repos)
    ++ (lib.mapAttrsToList (repoId: repoCfg: {
      assertion = lib.hasAttr repoCfg.secretName secrets;
      message = ''
        services.github-webhook.repos.${repoId}.secretName="${repoCfg.secretName}"
        is not defined in config.sops.secrets.
      '';
    }) cfg.repos);

    systemd.services.github-webhook =
      let
        # Collect all working directories for ConditionPathExists.
        workingDirs = lib.unique (
          lib.mapAttrsToList (_: repoCfg: repoCfg.workingDir) cfg.repos
        );

        # Collect all secrets for LoadCredential. Dedup entries so multiple
        # repos can safely share one secret.
        credentialsList = lib.unique (
          lib.mapAttrsToList (
            _: repoCfg:
            "${repoCfg.secretName}:${config.sops.secrets.${repoCfg.secretName}.path}"
          ) cfg.repos
        );
      in
      {
        description = "GitHub webhook listener";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        path = [
          pkgs.gitMinimal
          pkgs.openssh
        ];

        unitConfig = {
          # Check that at least one working directory exists.
          ConditionPathExists = workingDirs;
        };

        environment = {
          CONFIG_PATH = configFile;
          # Use a private runtime dir so ssh IdentityAgent expansion works
          # without a login session.
          XDG_RUNTIME_DIR = "%t/github-webhook";
        };

        serviceConfig = {
          ExecStart = "${cfg.package}/bin/github-webhook";
          User = cfg.user;
          Restart = "on-failure";
          RestartSec = 5;
          RuntimeDirectory = "github-webhook";
          RuntimeDirectoryMode = "0700";

          LoadCredential = credentialsList;

          # Hardening
          LockPersonality = true;
          NoNewPrivileges = true;
          ProtectControlGroups = true;
          ProtectHome = "read-only";
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "full";
          ReadWritePaths = workingDirs;
          RestrictSUIDSGID = true;
        };
      };
  };
}
