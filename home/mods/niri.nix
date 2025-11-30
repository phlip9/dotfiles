{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  xdg.configFile."niri/config.kdl".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/niri/config.kdl";
}
