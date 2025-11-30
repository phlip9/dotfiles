{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  home.file.".inputrc".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/readline/inputrc";
}
