{ config, pkgs, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  home.packages = [
    # unidirectional live sync daemon
    pkgs.lsyncd
    # lsyncd depends on rsync
    pkgs.rsync
  ];

  # symlink ~/.config/lsyncd -> ~/dev/dotfiles/config/lsyncd
  xdg.configFile."lsyncd".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/lsyncd";
}
