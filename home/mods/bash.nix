{config, pkgs, ...}: {
  programs.bash = {
    enable = true;

    # enable completion for all interactive shells
    enableCompletion = true;

    initExtra = ''
      source ${config.home.dotfilesDir}/bashrc
    '';
  };

  home.packages = [
    pkgs.bashInteractive
  ];
}
