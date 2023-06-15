{pkgs, ...}: {
  home.packages = [
    pkgs.universal-ctags
  ];

  xdg.configFile."ctags".source = ../../ctags.d;
}
