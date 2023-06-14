{config, ...}: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;

    withNodeJs = false;
    withPython3 = true;
    withRuby = false;
  };

  # link nvim config
  home.file."nvim" = {
    source = ../../nvim;
    target = "${config.xdg.configHome}/nvim";
    recursive = false;
  };
}
