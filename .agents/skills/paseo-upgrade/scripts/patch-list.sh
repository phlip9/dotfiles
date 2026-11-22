#!/usr/bin/env bash
# Print the patches nixos/pkgs/paseo/default.nix actually ships, in `patches`
# order, one file name per line. Asks nix instead of parsing the file, so
# comments (`#` or `/* */`) and any other nix syntax can't make it disagree
# w/ the build. Only our patches (files in nixos/pkgs/paseo/) are listed. The
# single source for import-patches.sh, export-patches.sh, and paseo-dev.
#
# usage: patch-list.sh
set -euo pipefail

root=$(git rev-parse --show-toplevel)
patches=$(nix eval --raw -f "$root" paseo.patches --apply "patches:
  builtins.concatStringsSep \"\\n\" (map baseNameOf (builtins.filter
    (path: dirOf path == \"$root/nixos/pkgs/paseo\") (map toString patches)))")
if [[ -z $patches ]]; then
  echo "error: paseo.patches lists none of nixos/pkgs/paseo/*.patch" >&2
  exit 1
fi
echo "$patches"
