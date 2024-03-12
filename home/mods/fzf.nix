# fzf - fuzzy finder <https://github.com/junegunn/fzf>
{
  lib,
  pkgs,
  ...
}: {
  programs.fzf = let
    stripNewlines = str: builtins.replaceStrings ["\n"] [""] str;

    defaultCommand = stripNewlines ''
      ${lib.getBin pkgs.fd}/bin/fd
        --type=file --fixed-strings --ignore-case --follow --hidden
        --exclude=".git/*" --exclude="target/*" --exclude="tags"
    '';
  in {
    enable = true;

    enableBashIntegration = true;
    enableZshIntegration = false;
    enableFishIntegration = false;

    # Use `fd` filename search for plain `fzf` invocation and `CTRL-T` keybind.
    defaultCommand = defaultCommand;

    fileWidgetCommand = defaultCommand + " --color=always";
    fileWidgetOptions = ["--ansi"];
  };
}
