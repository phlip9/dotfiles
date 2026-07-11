#!/usr/bin/env bash
set -euo pipefail

# substituted in nix derivation
readonly terranix="@terranix@"

# NOTE(phlip9): explicitly use global `nix`

# Use the repo's pinned nixpkgs unless the caller supplies one.
for arg in "$@"; do
  if [[ $arg == --pkgs ]]; then
    exec "$terranix" "$@"
  fi
done

nixpkgs="$(nix eval --file . --raw sources.nixpkgs.outPath)"
exec "$terranix" --pkgs "$nixpkgs" "$@"
