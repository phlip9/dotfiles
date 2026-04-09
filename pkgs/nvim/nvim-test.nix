# Run plenary busted tests for nvim lua modules.
#
# Build with:
#   nix build -f . --no-link phlipPkgs.nvim.tests.nvim-test
{
  coreutils,
  filter ? "",
  gitMinimal,
  lib,
  nvim,
  runCommandLocal,
  which,
}:

let
  # TODO(phlip9): use lib.fileset when we need more complicated file filtering.
  srcNvim = ../../nvim;
in

runCommandLocal "nvim-test"
  {
    nativeBuildInputs = [
      coreutils
      gitMinimal
      nvim
      which
    ];

    passthru = {
      inherit srcNvim;
    };
  }
  ''
    set -euo pipefail

    filter=${lib.escapeShellArg filter}

    # Setup temp XDG dirs
    export HOME="$TMPDIR/home"
    export XDG_CONFIG_HOME="$TMPDIR/config"
    export XDG_DATA_HOME="$TMPDIR/data"
    export XDG_STATE_HOME="$TMPDIR/state"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" \
      "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMPDIR/dotfiles"

    # nvim looks for config in $XDG_CONFIG_HOME/nvim
    ln -s "${srcNvim}" "$XDG_CONFIG_HOME/nvim"

    # setup "dotfiles" coc-settings.json and .luarc.json
    cd "$TMPDIR/dotfiles"
    mkdir -p .vim
    cp "${nvim.dotfilesCocSettingsFile}" .vim/coc-settings.json
    cp "${nvim.dotfilesLuarcJsonFile}" .luarc.json

    # Resolve filter to a directory under nvim/ for PlenaryBustedDirectory.
    test_dir="$XDG_CONFIG_HOME/nvim/lua/test"
    if [ -z "$filter" ]; then
      :
    else
      test_target="$XDG_CONFIG_HOME/nvim/$filter"
      if [ -f "$test_target" ]; then
        case "$test_target" in
          *_spec.lua) ;;
          *)
            echo "nvim-test: filter '$filter' is not a *_spec.lua test file" >&2
            exit 1
            ;;
        esac
        test_dir="$TMPDIR/filtered-tests"
        mkdir -p "$test_dir"
        # Plenary discovers specs with `find -type f`, so copy instead of
        # symlinking to ensure the filtered spec is discovered.
        cp "$test_target" "$test_dir/$(basename "$test_target")"
      elif [ -d "$test_target" ]; then
        test_dir="$test_target"
      else
        echo "nvim-test: filter '$filter' is not a file or directory" >&2
        echo "nvim-test: expected a path relative to nvim/" >&2
        exit 1
      fi
    fi

    # Run plenary busted tests via one consistent code path.
    # Pass `init` so plenary child processes load our init.lua and plugins
    # (without it, plenary defaults to --noplugin).
    nvim --headless \
      -c "PlenaryBustedDirectory $test_dir {nvim_cmd = '$(which nvim)', init = '$XDG_CONFIG_HOME/nvim/init.lua'}"

    touch "$out"
  ''
