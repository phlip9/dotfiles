{
  config,
  pkgs,
  ...
}: {
  home.packages = [
    pkgs.universal-ctags
  ];

  home.file."ctags" = {
    source = ../../ctags.d;
    target = "${config.xdg.configHome}/ctags";
    recursive = false;
  };
}
