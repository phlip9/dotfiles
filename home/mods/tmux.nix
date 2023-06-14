{
  config,
  pkgs,
  ...
}: {
  home.packages = [
    pkgs.tmux
  ];

  # link tmux.conf
  home.file."tmux-conf" = {
    source = ../../tmux.conf;
    target = "${config.home.homeDirectory}/.tmux.conf";
  };
}
