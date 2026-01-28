# Run plenary busted tests for nvim lua modules.
#
# Build with:
#   nix build -f . --no-link phlipPkgs.nvim.tests.nvim-test
{
  coreutils,
  gitMinimal,
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

    # Run plenary busted tests
    nvim --headless \
      -c "PlenaryBustedDirectory $XDG_CONFIG_HOME/nvim/lua/test {nvim_cmd = '$(which nvim)'}"

    touch "$out"
  ''
