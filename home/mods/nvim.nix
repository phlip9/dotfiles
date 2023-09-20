{config, pkgs, ...}:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;

  neovimConfig = (pkgs.neovimUtils.makeNeovimConfig {
    withPython3 = true;
    withNodeJs = false; # TODO: get coc.nvim working
  }) // { # Args passed to `wrapNeovimUnstable`
    # Don't manage config, we'll just symlink to our `dotfiles/nvim/init.vim`.
    wrapRc = false;
  };
in {
  # Using a manually configured neovim w/o home-manager's config so I can get
  # the nvim config dir symlink working.

  home.packages = [
    (pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped neovimConfig)

    # TODO: just add this to wrapped `nvim` PATH instead
    pkgs.nil
  ];

  # symlink ~/.config/nvim to `dotfiles/nvim` dir.
  xdg.configFile."nvim".source = mkOutOfStoreSymlink "${dotfilesDir}/nvim";
}
