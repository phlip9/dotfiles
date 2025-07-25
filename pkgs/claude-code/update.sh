#!/usr/bin/env nix
#!nix shell nixpkgs#bash nixpkgs#nix-update nixpkgs#nodePackages.npm --command bash

set -euo pipefail

version=$(npm view @anthropic-ai/claude-code version)

# Generate updated lock file
pushd "$(dirname "${BASH_SOURCE[0]}")"
npm i --package-lock-only @anthropic-ai/claude-code@"$version"
rm -f package.json
popd

# Update version and hashes
nix-update packages.currentSystem.claude-code --version "$version"
