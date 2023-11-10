# A manually configured neovim w/o home-manager's config so I can get the nvim
# config dir symlink working.
{
  config,
  pkgs,
  lib,
  ...
}: let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;

  # packages to add to the nvim PATH w/o infecting whole env
  # TODO: mkOption
  extraPkgs = [
    # semi-functioning nix language server.
    # maybe someday nix users won't have to live in fucking squalor...
    pkgs.nil
  ];
  extraPkgsPath = lib.makeBinPath extraPkgs;

  neovimConfigBase = pkgs.neovimUtils.makeNeovimConfig {
    withNodeJs = true; # used by `coc.nvim` LSP client
    withPython3 = false;
    withRuby = false;
  };

  # Need some args passed directly to `wrapNeovimUnstable`
  neovimConfig =
    neovimConfigBase
    // {
      # Don't manage config, we'll just symlink to our `dotfiles/nvim/init.vim`.
      wrapRc = false;
      # Inject extra packages into nvim PATH.
      wrapperArgs = neovimConfigBase.wrapperArgs ++ ["--suffix" "PATH" ":" extraPkgsPath];
    };
in {
  home.packages = [
    (pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped neovimConfig)
  ];

  # symlink ~/.config/nvim to `dotfiles/nvim` dir.
  xdg.configFile."nvim".source = mkOutOfStoreSymlink "${dotfilesDir}/nvim";
}
