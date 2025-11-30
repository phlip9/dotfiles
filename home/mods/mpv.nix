{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  # configs + keybinds
  xdg.configFile."mpv".source = mkOutOfStoreSymlink "${dotfilesDir}/config/mpv";
}
