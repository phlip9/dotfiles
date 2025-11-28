{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  # configs + keybinds
  xdg.configFile."mpv/mpv.conf".source =
    mkOutOfStoreSymlink "${dotfilesDir}/mpv/mpv.conf";
  xdg.configFile."mpv/input.conf".source =
    mkOutOfStoreSymlink "${dotfilesDir}/mpv/input.conf";
}
