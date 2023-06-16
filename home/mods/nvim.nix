{pkgs, ...}: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;

    withNodeJs = false;
    withPython3 = true;
    withRuby = false;
  };

  home.packages = [
    pkgs.nil
  ];

  # link ~/.config/nvim to dotfiles/nvim
  xdg.configFile."nvim".source = ../../nvim;
}
