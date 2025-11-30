{ config, pkgs, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  home.packages = [
    pkgs.universal-ctags
  ];

  xdg.configFile."ctags".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/ctags";
}
