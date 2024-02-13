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

    plugins = let
      p = pkgs.vimPlugins;
    in [
      # kanagawa - neovim colorscheme
      { plugin = p.kanagawa-nvim; }

      # nvim-treesitter - tree-sitter interface and syntax highlighting
      { plugin = p.nvim-treesitter.withPlugins (q: [
        # available language plugins:
        # <https://github.com/NixOS/nixpkgs/blob/master/pkgs/applications/editors/vim/plugins/nvim-treesitter/generated.nix>
        q.bash
        q.c
        q.cmake
        q.cpp
        q.css
        q.diff
        q.dockerfile
        q.git_rebase
        q.gitcommit
        q.gitignore
        q.html
        q.ini
        q.javascript
        q.json
        q.jsonc
        q.lua
        q.make
        q.markdown
        q.nix
        q.python
        q.query
        q.rust
        q.toml
        q.vim
        q.vimdoc
        q.yaml
      ]); }

      # vim-airline - Lightweight yet fancy status line
      { plugin = p.vim-airline; }

      # vim-fugitive - Vim Git integration
      { plugin = p.vim-fugitive; }

      # vim-gitgutter - Show git diff in the gutter
      { plugin = p.vim-gitgutter; }

      # NERDCommenter - Easily comment lines or blocks of text
      { plugin = p.nerdcommenter; }

      # delimitMate - Autocompletion for delimiters
      { plugin = p.delimitMate; }
    ];
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
