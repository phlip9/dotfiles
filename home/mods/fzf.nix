# fzf - fuzzy finder <https://github.com/junegunn/fzf>
{
  lib,
  pkgs,
  ...
}: {
  programs.fzf = rec {
    enable = true;

    enableBashIntegration = true;
    enableZshIntegration = false;
    enableFishIntegration = false;

    # Use `fd` filename search for plain `fzf` invocation and `CTRL-T` keybind.
    defaultCommand = "${lib.getBin pkgs.fd}/bin/fd \
      --type file --fixed-strings --ignore-case --follow --hidden \
      --exclude \".git/*\" --exclude \"target/*\""; 

    fileWidgetCommand = defaultCommand + " --color=always";
    fileWidgetOptions = ["--ansi"];
  };
}
