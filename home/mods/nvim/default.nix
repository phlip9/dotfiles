# A manually configured neovim w/o home-manager's config so I can get the nvim
# config dir symlink working.
{
  config,
  phlipPkgs,
  pkgs,
  lib,
  ...
}:
let
  inherit (builtins) map;

  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;

  # packages to add to the nvim PATH w/o infecting whole env
  extraPkgs = [
    # tools
    pkgs.bat
    pkgs.fd
    pkgs.ripgrep

    # semi-functioning nix language server.
    # maybe someday nix users won't have to live in fucking squalor...
    pkgs.nil

    # preferred nix formatter
    pkgs.alejandra
    # nixpkgs repo formatter
    phlipPkgs.nixfmt
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
  extraPluginsGenerated = pkgs.callPackage ./nvim-extra-plugins.generated.nix {
    buildVimPlugin = pkgs.vimUtils.buildVimPlugin;
    buildNeovimPlugin = pkgs.neovimUtils.buildNeovimPlugin;
  };

  # All vim/nvim plugins + a few non-nixpkgs plugins overlayed
  p = pkgs.vimPlugins.extend extraPluginsGenerated;

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
  neovimConfigBase = pkgs.neovimUtils.makeNeovimConfig {
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

  # Need a coc-settings.json specific to our dotfiles directory for good
  # autocompletion that includes all our plugins.
  myDotfilesSpecificCocSettings = {
    "sumneko-lua.serverDir" =
      "${pkgs.lua-language-server}/share/lua-language-server";
    "Lua.runtime.version" = "LuaJIT";
    "Lua.workspace.library" = map (x: "${x.plugin.outPath}/lua") luaPlugins;
  };
  myDotfilesSpecificCocSettingsFile = pkgs.writers.writeJSON "coc-settings.json" myDotfilesSpecificCocSettings;

  # .luarc.json for CLI lua-language-server --check
  myLuarcJson = {
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
        [ "${pkgs.neovim-unwrapped}/share/nvim/runtime/lua" ]
        # nvim lua plugin libraries
        ++ map (x: "${x.plugin.outPath}/lua") luaPlugins;
    };
    diagnostics = {
      libraryFiles = "Disable";
      disable = [ "redefined-local" ];
      # neovim globals
      globals = [ "vim" ];
    };
  };
  myLuarcJsonFile = pkgs.writers.writeJSON ".luarc.json" myLuarcJson;

  # The final, wrapped neovim package.
  finalNeovimPackage = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped neovimConfig;
in
{
  home.packages = [
    finalNeovimPackage
  ];

  # use nvim as our man pager
  # - set `MANWIDTH=999` b/c man pages are hardwrapped at a few columns too
  #   much. "disable" hardwrap with this env.
  programs.bash.initExtra = ''
    export MANPAGER="${finalNeovimPackage}/bin/nvim +Man!"
    export MANWIDTH=999
  '';

  # symlink ~/.config/nvim to `dotfiles/nvim` dir.
  xdg.configFile."nvim".source = mkOutOfStoreSymlink "${dotfilesDir}/nvim";

  # Configure the lua LSP for local nvim plugin development.
  home.file."dev/dotfiles/.vim/coc-settings.json".source = "${
    myDotfilesSpecificCocSettingsFile
  }";

  # .luarc.json for CLI lua-language-server --check (used by `just nvim-lint`)
  home.file."dev/dotfiles/.luarc.json".source = "${myLuarcJsonFile}";
}
