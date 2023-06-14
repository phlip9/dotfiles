{config, ...}: {
  home.file."inputrc" = {
    source = ../../inputrc;
    target = "${config.home.homeDirectory}/.inputrc";
  };
}
