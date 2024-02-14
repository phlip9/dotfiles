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
    pkgs.alejandra
  ];
  extraPkgsPath = lib.makeBinPath extraPkgs;

  neovimConfigBase = pkgs.neovimUtils.makeNeovimConfig {
    withNodeJs = true; # used by `coc.nvim` LSP client
    withPython3 = false;
    withRuby = false;

    # Full list of plugins in nixpkgs:
    # <https://github.com/NixOS/nixpkgs/blob/master/pkgs/applications/editors/vim/plugins/generated.nix>
    plugins = let
      # Our non-nixpkgs plugins. Use these to either track a plugin off a
      # different branch/rev or temporarily use a plugin before it's added to
      # nixpkgs.
      #
      # To update:
      #
      # ```bash
      # just update-nvim-extra-plugins
      # ```
      extraPlugins = pkgs.callPackage ./nvim-extra-plugins.generated.nix {
        buildVimPlugin = pkgs.vimUtils.buildVimPlugin;
        buildNeovimPlugin = pkgs.neovimUtils.buildNeovimPlugin;
      };

      p = pkgs.vimPlugins.extend extraPlugins;
    in [
      # kanagawa - neovim colorscheme
      # TODO(phlip9): use nixpkgs master after next update
      {plugin = p.kanagawa-nvim;}

      # nvim-treesitter - tree-sitter interface and syntax highlighting
      {
        plugin = p.nvim-treesitter.withPlugins (q: [
          # available language plugins:
          # <https://github.com/NixOS/nixpkgs/blob/master/pkgs/applications/editors/vim/plugins/nvim-treesitter/generated.nix>
          q.bash
          q.c
          q.cmake
          q.cpp
          q.css
          q.csv
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
        ]);
      }

      # vim-airline - Lightweight yet fancy status line
      {plugin = p.vim-airline;}

      # vim-fugitive - Vim Git integration
      {plugin = p.vim-fugitive;}

      # vim-gitgutter - Show git diff in the gutter
      {plugin = p.vim-gitgutter;}

      # NERDCommenter - Easily comment lines or blocks of text
      {plugin = p.nerdcommenter;}

      # delimitMate - Autocompletion for delimiters
      {plugin = p.delimitMate;}

      # SudoEdit.vim - Easily write to protected files
      {plugin = p.SudoEdit-vim;}

      # fzf.vim - fuzzy file matching, grepping, and tag searching using fzf
      {plugin = p.fzf-vim;}

      # coc.nvim - Complete engine and Language Server support for neovim
      {plugin = p.coc-nvim;}
      {plugin = p.coc-fzf;}

      # coc.nvim - LSP integrations
      {plugin = p.coc-flutter;}
      {plugin = p.coc-json;}
      {plugin = p.coc-rust-analyzer;}
      {plugin = p.coc-toml;}
      {plugin = p.coc-vimlsp;}
      {plugin = p.coc-yaml;}

      # goyo.vim - distraction free editing
      {plugin = p.goyo-vim;}

      # Recover.vim - Show a diff when recovering swp files
      {plugin = p.Recover-vim;}

      # vim-bbye - Close a buffer without messing up your layout
      {plugin = p.vim-bbye;}

      # vim-just - Justfile syntax
      {plugin = p.vim-just;}
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