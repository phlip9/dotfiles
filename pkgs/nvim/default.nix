# Wrapped neovim with plugins and tools.
#
# Configured manually (not using home-manager's programs.neovim) so we can
# symlink the config directory to `dotfiles/nvim/`.
#
# See also: home/mods/nvim/default.nix
{
  lib,
  callPackage,
  writers,

  # neovim
  neovim-unwrapped,
  neovimUtils,
  wrapNeovimUnstable,
  vimPlugins,
  vimUtils,

  # extra PATH packages
  alejandra,
  bat,
  fd,
  lua-language-server,
  nil,
  nixfmt-rfc-style,
  ripgrep,
}:
let
  inherit (builtins) map;

  # packages to add to the nvim PATH w/o infecting whole env
  extraPkgs = [
    # tools
    bat
    fd
    ripgrep

    # semi-functioning nix language server.
    # maybe someday nix users won't have to live in fucking squalor...
    nil

    # preferred nix formatter
    alejandra
    # nixpkgs repo formatter
    # TODO(phlip9): change to `nixfmt` after release-25.11
    nixfmt-rfc-style
  ];
  extraPkgsPath = lib.makeBinPath extraPkgs;

  # Our non-nixpkgs plugins. Use these to either track a plugin off a
  # different branch/rev or temporarily use a plugin before it's added to
  # nixpkgs.
  #
  # To update:
  #
  # ```bash
  # just update-nvim-extra-plugins
  # ```
  extraPluginsGenerated = callPackage ./nvim-extra-plugins.generated.nix {
    buildVimPlugin = vimUtils.buildVimPlugin;
    buildNeovimPlugin = neovimUtils.buildNeovimPlugin;
  };

  # All vim/nvim plugins + a few non-nixpkgs plugins overlayed
  p = vimPlugins.extend extraPluginsGenerated;

  # The _lua_ plugins we're actually using. These are separated out so we can
  # add these the lua LSP config when we're working on our nvim config.
  luaPlugins = [
    # copilot.vim
    { plugin = p.copilot-vim; }

    # kanagawa - neovim colorscheme
    { plugin = p.kanagawa-nvim; }

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
        q.dart
        q.diff
        q.dockerfile
        q.git_rebase
        q.gitcommit
        q.gitignore
        q.html
        q.ini
        q.javascript
        q.jq
        q.json
        q.jsonc
        q.just
        q.kotlin
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
        q.xml
        q.yaml
      ]);
    }
    # phlip9: disabled this plugin since it seems to perform poorly and is buggy
    # # nvim-treesitter-context - show the context that's past the scroll height
    # {plugin = p.nvim-treesitter-context;}

    # nvim-treesitter-endwise - auto-add `end` block to lua, bash, ruby, etc...
    { plugin = p.nvim-treesitter-endwise; }
    # nvim-treesitter-textobjects - syntax aware text objs + motions
    { plugin = p.nvim-treesitter-textobjects; }

    # plenary.nvim - missing std for neovim lua. testing utils.
    { plugin = p.plenary-nvim; }

    # telescope.nvim - fuzzy picker framework
    { plugin = p.telescope-nvim; }
    # telescope-fzf-native - use native impl fzf algorithm to speed up matching
    { plugin = p.telescope-fzf-native-nvim; }
    # telescope-coc-nvim - telescope x coc.nvim integration
    { plugin = p.telescope-coc-nvim; }

    # baleia.nvim - Colorize text with ANSI escape sequences.
    { plugin = p.baleia-nvim; }
  ];

  # All plugins we're actually using.
  plugins = luaPlugins ++ [
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

    # SudoEdit.vim - Easily write to protected files
    { plugin = p.SudoEdit-vim; }

    # fzf.vim - fuzzy file matching, grepping, and tag searching using fzf
    { plugin = p.fzf-vim; }

    # coc.nvim - Complete engine and Language Server support for neovim
    { plugin = p.coc-nvim; }
    { plugin = p.coc-fzf; }

    # coc.nvim - LSP integrations
    { plugin = p.coc-flutter; }
    { plugin = p.coc-json; }
    { plugin = p.coc-rust-analyzer; }
    { plugin = p.coc-sumneko-lua; }
    { plugin = p.coc-toml; }
    { plugin = p.coc-vimlsp; }
    { plugin = p.coc-yaml; }

    # goyo.vim - distraction free editing
    { plugin = p.goyo-vim; }

    # Recover.vim - Show a diff when recovering swp files
    { plugin = p.Recover-vim; }

    # vim-bbye - Close a buffer without messing up your layout
    { plugin = p.vim-bbye; }
  ];

  # Using the nixpkgs helper fn as a base, with some manual overrides added after.
  neovimConfigBase = neovimUtils.makeNeovimConfig {
    withNodeJs = true; # used by `coc.nvim` LSP client
    withPython3 = true; # used by `coc-fzf` symbols
    withRuby = false;

    # Full list of plugins in nixpkgs:
    # <https://github.com/NixOS/nixpkgs/blob/master/pkgs/applications/editors/vim/plugins/generated.nix>
    plugins = plugins;
  };

  # Need some args passed directly to `wrapNeovimUnstable`
  neovimConfig = neovimConfigBase // {
    # Don't manage config, we'll just symlink to our `dotfiles/nvim/init.vim`.
    wrapRc = false;
    # Inject extra packages into nvim PATH.
    wrapperArgs = neovimConfigBase.wrapperArgs ++ [
      "--suffix"
      "PATH"
      ":"
      extraPkgsPath
    ];
  };

  # The final, wrapped neovim package.
  finalNeovimPackage = wrapNeovimUnstable neovim-unwrapped neovimConfig;

  # Lua plugin library paths for lua LSP workspace.library config.
  luaPluginLibraryPaths = map (x: "${x.plugin.outPath}/lua") luaPlugins;

  # coc-settings.json for lua LSP when editing dotfiles nvim config.
  dotfilesCocSettings = {
    "sumneko-lua.serverDir" = "${lua-language-server}/share/lua-language-server";
    "Lua.runtime.version" = "LuaJIT";
    "Lua.workspace.library" = luaPluginLibraryPaths;
  };
  dotfilesCocSettingsFile = writers.writeJSON "coc-settings.json" dotfilesCocSettings;

  # .luarc.json for CLI lua-language-server --check (used by `just nvim-lint`)
  dotfilesLuarcJson = {
    "$schema" =
      "https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json";
    runtime = {
      version = "LuaJIT";
      pathStrict = true;
    };
    workspace = {
      ignoreSubmodules = true;
      checkThirdParty = false;
      library =
        # neovim runtime for vim.* types
        [ "${neovim-unwrapped}/share/nvim/runtime/lua" ]
        # nvim lua plugin libraries
        ++ luaPluginLibraryPaths;
    };
    diagnostics = {
      libraryFiles = "Disable";
      disable = [ "redefined-local" ];
      # neovim globals
      globals = [ "vim" ];
    };
  };
  dotfilesLuarcJsonFile = writers.writeJSON ".luarc.json" dotfilesLuarcJson;
in
finalNeovimPackage.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit
      luaPlugins
      dotfilesCocSettingsFile
      dotfilesLuarcJsonFile
      ;
  };
})
