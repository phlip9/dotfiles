{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  xdg.configFile."gdb".source = mkOutOfStoreSymlink "${dotfilesDir}/config/gdb";
}
