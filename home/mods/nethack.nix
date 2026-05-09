{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  home.file.".nethackrc".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/nethack/nethackrc";
}
