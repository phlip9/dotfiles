#!/usr/bin/env nix
#!nix shell nixpkgs#bash nixpkgs#nix-update nixpkgs#nodePackages.npm --command bash

set -euo pipefail

version=$(npm view @anthropic-ai/claude-code version)

# Generate updated lock file
pushd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null
npm i --package-lock-only @anthropic-ai/claude-code@"$version"
rm -f package.json
popd > /dev/null

# Update version and hashes
nix-update claude-code --version "$version"
