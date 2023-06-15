{...}: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;

    withNodeJs = false;
    withPython3 = true;
    withRuby = false;
  };

  # link ~/.config/nvim to dotfiles/nvim
  xdg.configFile."nvim".source = ../../nvim;
}
