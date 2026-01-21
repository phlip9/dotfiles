# Run omnara as a background daemon service.
{
  config,
  lib,
  phlipPkgs,
  pkgs,
  ...
}:
let
  isLinux = pkgs.hostPlatform.isLinux;
  isDarwin = pkgs.hostPlatform.isDarwin;

  omnara = phlipPkgs.omnara;

  homeDir = config.home.homeDirectory;

  # Run as a login shell so we get normal PATH + aliases
  execStart = [
    "${pkgs.bashInteractive}/bin/bash"
    "-lc"
    "'exec ${omnara}/bin/omnara daemon run-service'"
  ];
in
{
  # Add omnara to PATH
  home.packages = [ omnara ];

  # Linux - systemd user service
  systemd.user.services.omnara = lib.mkIf isLinux {
    Install.WantedBy = [ "default.target" ];

    Unit = {
      Description = "Omnara Background Daemon";
      After = [ "network.target" ];
    };

    Service = {
      Type = "simple";
      ExecStart = builtins.concatStringsSep " " execStart;
      Restart = "on-failure";
      RestartSec = 5;
      WorkingDirectory = homeDir;
    };
  };

  # macOS - launchd agent
  launchd.agents.omnara = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProcessType = "Background";
      ProgramArguments = execStart;
      WorkingDirectory = homeDir;
      RunAtLoad = true;
      KeepAlive = {
        SuccessfulExit = false;
        Crashed = true;
      };
      ThrottleInterval = 5;
    };
  };
}
