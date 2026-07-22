# Run the Paseo daemon on a workstation.
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

  # Seed the environment before sourcing Home Manager's generated session
  # variables. home.sessionPath adds personal paths to this baseline.
  servicePath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "/nix/var/nix/profiles/default/bin"
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

    ${pkgs.coreutils}/bin/install -d -m 0700 "$PASEO_HOME"

    ${pkgs.openssl}/bin/openssl rand -hex 32 > "$PASEO_PASSWORD_FILE"
    ${pkgs.coreutils}/bin/chmod 0600 "$PASEO_PASSWORD_FILE"

    exec ${
      lib.escapeShellArgs (
        [ "${cfg.package}/bin/paseo-server" ]
        ++ lib.optional (!cfg.relay.enable) "--no-relay"
      )
    }
  '';
in
{
  options.services.paseo = {
    enable = lib.mkEnableOption "Paseo daemon launchd service";

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

    # Make the CLI target the launchd-managed local daemon by default.
    home.sessionVariables = {
      PASEO_APP_BASE_URL = "https://paseo.phlip9.com";
      PASEO_HOME = cfg.dataDir;
      PASEO_HOST = listen;
      PASEO_PASSWORD_FILE = passwordFile;
      PASEO_RELAY_ENABLED = lib.boolToString cfg.relay.enable;
      PASEO_RELAY_ENDPOINT = hostPort cfg.relay.host cfg.relay.port;
      PASEO_RELAY_USE_TLS = lib.boolToString cfg.relay.useTls;
    };

    # paseo macOS launchd service
    launchd.agents.paseo = {
      enable = true;
      config = {
        Program = runPaseo;
        WorkingDirectory = homeDir;

        EnvironmentVariables = {
          NODE_ENV = "production";
          PASEO_LISTEN = listen;
          PASEO_WEB_UI_ENABLED = "false";

          PASEO_APP_BASE_URL = "https://paseo.phlip9.com";
          PASEO_HOME = cfg.dataDir;
          PASEO_HOST = listen;
          PASEO_PASSWORD_FILE = passwordFile;
          PASEO_RELAY_ENABLED = lib.boolToString cfg.relay.enable;
          PASEO_RELAY_ENDPOINT = hostPort cfg.relay.host cfg.relay.port;
          PASEO_RELAY_USE_TLS = lib.boolToString cfg.relay.useTls;
        };

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
