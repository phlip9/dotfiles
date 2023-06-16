{pkgs, ...}: {
  programs.bash = {
    enable = true;

    # enable completion for all interactive shells
    enableCompletion = true;

    initExtra = ''
      source ${../../bashrc}
    '';
  };

  home.packages = [
    pkgs.bashInteractive
  ];
}
