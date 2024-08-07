# TODO: figure out why alacritty isn't working on my linux desktop. probably
#       some GUI/X11/wayland/idk library issue?
#
# ```bash
# $ alacritty -vvv
# Created log file at "/tmp/Alacritty-599442.log"
# [0.000006412s] [INFO ] [alacritty] Welcome to Alacritty
# [0.000067818s] [INFO ] [alacritty] Version 0.12.1
# [0.000075159s] [INFO ] [alacritty] Running on X11
# [0.000581404s] [INFO ] [alacritty] Configuration files loaded from:
#                                      "/home/phlip9/.config/alacritty/alacritty.yml"
#                                      "/nix/store/yvm40rd1rplmssfi4s7c41vsr3djh4ff-source/alacritty.yml"
# [0.002008730s] [INFO ] [alacritty] Using GLX 1.4
# Error: failed to find suitable GL configuration.
# [0.002356648s] [INFO ] [alacritty] Goodbye
# Deleted log file at "/tmp/Alacritty-599442.log"
# Error: "Event loop terminated with code: 1"
# ```
{
  config,
  lib,
  ...
}: let
  cfg = config.programs.alacritty;

  dotfilesDir = config.home.dotfilesDir;
in {
  # programs.alacritty.enable = true;
  # programs.alacritty.settings = {
  #   import = [
  #     (toString ../../alacritty.yml)
  #   ];
  # };

  options = {
    programs.alacritty.fontSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
    };
  };

  config = {
    # Why do this funky setup? So we get alacritty auto-reload on config file
    # change, while still overriding settings on different machines.
    xdg.configFile."alacritty/alacritty.toml".text = ''
      import = [
        "${dotfilesDir}/alacritty.toml",
      ]

      [font]
      size = ${builtins.toString cfg.fontSize}
    '';
  };
}
