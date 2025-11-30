{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  xdg.configFile."noctalia".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/noctalia";
}
