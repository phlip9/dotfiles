{
  config,
  pkgs,
  ...
}:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  home.packages = [ pkgs.tmux ];

  xdg.configFile."tmux".source = mkOutOfStoreSymlink "${dotfilesDir}/config/tmux";
}
