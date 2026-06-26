# Run paseo as a background user daemon service.
{
  config,
  lib,
  phlipPkgs,
  pkgs,
  ...
}:
let
  # isLinux = pkgs.stdenv.hostPlatform.isLinux;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  paseo = phlipPkgs.paseo;

  paseoHome = "${config.xdg.configHome}/paseo";

  cfg = config.services.paseo;

  # Run as a login shell so we get normal PATH + aliases
  execStart = [
    "${pkgs.bashInteractive}/bin/bash"
    "-lc"
    "exec ${paseo}/bin/paseo-server ${
      lib.optionalString (!cfg.relay.enable) "--no-relay"
    }"
  ];
in
{
  options.services.paseo = {
    enable = lib.mkEnableOption "self-hosted agent interface";

    relay = {
      enable = lib.mkEnableOption "remote relay";
    };
  };

  config = lib.mkIf cfg.enable {
    # Add paseo to PATH
    home.packages = [ paseo ];

    # Need some way to create this dir on macOS before the service starts
    xdg.configFile."paseo/.keep" = lib.mkIf isDarwin { text = ""; };

    # macOS - launchd agent
    launchd.agents.paseo = lib.mkIf isDarwin {
      enable = true;
      config = {
        ProcessType = "Background";
        # Run as a login shell so we get normal PATH + aliases
        ProgramArguments = [
          "${pkgs.bashInteractive}"
          "-lc"
          (pkgs.writeText "run-paseo.bash" ''
            set -euxo pipefail

            exec ${paseo}/bin/paseo-server ${
              lib.optionalString (!cfg.relay.enable) "--no-relay"
            }
          '')
        ];
        WorkingDirectory = paseoHome;
        StandardErrorPath = "${paseoHome}/paseo.err.log";
        # # stdout logs in ~/.config/paseo/daemon.log
        # StandardOutPath = "${paseoHome}/paseo.out.log";
        EnvironmentVariables = {
          NODE_ENV = "production";
          PASEO_HOME = paseoHome;
          PASEO_LISTEN = "[::1]:6767";
        };
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
          Crashed = true;
        };
        ThrottleInterval = 5;
      };
    };
  };
}
