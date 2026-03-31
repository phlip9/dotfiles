# Run omnara as a background daemon service.
{
  config,
  lib,
  phlipPkgs,
  pkgs,
  ...
}:
let
  isLinux = pkgs.stdenv.hostPlatform.isLinux;

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
}
