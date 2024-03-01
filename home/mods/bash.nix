{
  lib,
  config,
  pkgs,
  ...
}: {
  programs.bash = {
    enable = true;

    # enable completion for all interactive shells
    enableCompletion = true;

    # Manage our bashrc outside of nix.
    # Use `mkAfter` so it's sourced last, after all the other nix stuff.
    initExtra = lib.mkAfter ''
      source ${config.home.dotfilesDir}/bashrc
    '';
  };

  home.packages = [
    pkgs.bashInteractive
  ];
}
