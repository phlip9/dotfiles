# Run the Paseo daemon as a systemd/launchd user service.
{
  config,
  lib,
  phlipPkgs,
  pkgs,
  ...
}:

let
  cfg = config.services.paseo;
  homeDir = config.home.homeDirectory;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;

  # Seed the environment before sourcing Home Manager's generated session
  # variables. home.sessionPath adds personal paths to this baseline.
  servicePath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "/nix/var/nix/profiles/default/bin"
    "/run/current-system/sw/bin"
    "/run/wrappers/bin"
    "/usr/local/bin"
    "/usr/local/sbin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];

  isIpv6Addr = addr: lib.hasInfix ":" addr && !(lib.hasPrefix "[" addr);
  formatHost = addr: if isIpv6Addr addr then "[${addr}]" else addr;
  hostPort = addr: port: "${formatHost addr}:${toString port}";

  listen = hostPort cfg.listenAddress cfg.port;
  passwordFile = "${cfg.dataDir}/daemon-password";

  # shared CLI and daemon envs
  paseoEnvs = {
    PASEO_APP_BASE_URL = "https://paseo.phlip9.com";
    PASEO_HOME = cfg.dataDir;
    PASEO_HOST = listen;
    PASEO_PASSWORD_FILE = passwordFile;
    PASEO_RELAY_ENABLED = lib.boolToString cfg.relay.enable;
    PASEO_RELAY_ENDPOINT = hostPort cfg.relay.host cfg.relay.port;
    PASEO_RELAY_USE_TLS = lib.boolToString cfg.relay.useTls;
  };

  # daemon-only envs
  daemonEnvs = paseoEnvs // {
    NODE_ENV = "production";
    # Disable unused speech features and their model downloads.
    PASEO_DICTATION_ENABLED = "false";
    PASEO_LISTEN = listen;
    PASEO_VOICE_MODE_ENABLED = "false";
    PASEO_WEB_UI_ENABLED = "false";
  };

  # Source the same declarative environment as interactive shells without
  # depending on mutable login-shell startup files. Paseo terminals inherit
  # SHELL below and load the normal bashrc when they start a PTY.
  runPaseo = pkgs.writeShellScript "run-paseo-daemon" ''
    set -eo pipefail

    ${config.lib.shell.exportAll {
      HOME = homeDir;
      SHELL = lib.getExe config.programs.bash.package;
      PATH = servicePath;
    }}

    unset __HM_SESS_VARS_SOURCED
    # shellcheck source=/dev/null
    source ${"${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"}

    set -u

    ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 "$PASEO_HOME"

    ${lib.getExe pkgs.openssl} rand -hex 32 > "$PASEO_PASSWORD_FILE"
    ${lib.getExe' pkgs.coreutils "chmod"} 0600 "$PASEO_PASSWORD_FILE"

    exec ${
      lib.escapeShellArgs (
        [ "${lib.getExe' cfg.package "paseo-server"}" ]
        ++ lib.optional (!cfg.relay.enable) "--no-relay"
      )
    }
  '';
in
{
  options.services.paseo = {
    enable = lib.mkEnableOption "Paseo daemon user service";

    package = lib.mkOption {
      type = lib.types.package;
      default = phlipPkgs.paseo;
      description = "Paseo daemon and CLI package.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/paseo";
      description = "Private Paseo state directory (PASEO_HOME).";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Local address on which the Paseo daemon listens.

        NOTE(phlip9): paseo CLI struggles with IPv6, so avoid that for now...
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6767;
      description = "Local port on which the Paseo daemon listens.";
    };

    relay = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Connect the daemon to the remote Paseo relay.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "relay.paseo.phlip9.com";
        description = "Remote Paseo relay hostname.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 443;
        description = "Remote Paseo relay port.";
      };

      useTls = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use TLS for daemon and client relay connections.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.relay.enable -> cfg.relay.host != "";
        message = "services.paseo.relay.host must not be empty.";
      }
    ];

    # Make paseo CLI available
    home.packages = [ cfg.package ];

    # Make the CLI target the local daemon by default.
    home.sessionVariables = paseoEnvs;

    # paseo Linux systemd user service
    systemd.user.services.paseo = lib.mkIf isLinux {
      Unit = {
        Description = "Paseo - self-hosted daemon for AI coding agents";
        After = [ "network.target" ];
      };

      Install.WantedBy = [ "default.target" ];

      Service = {
        Type = "simple";
        ExecStart = runPaseo;
        WorkingDirectory = homeDir;
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") daemonEnvs;
        Restart = "on-failure";
        RestartSec = 10;
        KillSignal = "SIGTERM";
        TimeoutStopSec = 15;
      };
    };

    # paseo macOS launchd service
    launchd.agents.paseo = lib.mkIf isDarwin {
      enable = true;
      config = {
        Program = runPaseo;
        WorkingDirectory = homeDir;

        EnvironmentVariables = daemonEnvs;

        RunAtLoad = true;
        KeepAlive = {
          Crashed = true;
          SuccessfulExit = false;
        };
        # NOTE(phlip9): previously "Background", but agents would take like
        # an hour to run `cargo clippy` in work monorepo.
        ProcessType = "Standard";
        ThrottleInterval = 10;
        ExitTimeOut = 15;
      };
    };
  };
}
