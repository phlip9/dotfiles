{...}: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;

    withNodeJs = false;
    withPython3 = true;
    withRuby = false;
  };
}
