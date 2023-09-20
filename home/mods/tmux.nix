{config, pkgs, ...}:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in {
  home.packages = [
    pkgs.tmux
  ];

  # link tmux.conf
  home.file.".tmux.conf".source = mkOutOfStoreSymlink "${dotfilesDir}/tmux.conf";
}
