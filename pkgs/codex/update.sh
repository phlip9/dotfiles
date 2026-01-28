#!/usr/bin/env nix
#!nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix --command bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.json"

# Fetch latest version from GitHub releases API
echo "Fetching latest codex version..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/openai/codex/releases/latest" | jq -r '.tag_name')
VERSION="${LATEST_TAG#rust-v}"
echo "Latest version: $VERSION"

prefetch_hash() {
  local target=$1
  local url="https://github.com/openai/codex/releases/download/rust-v${VERSION}/codex-${target}.tar.gz"
  echo "Prefetching $target..." >&2
  nix store prefetch-file "$url" --json | jq -r '.hash'
}

X86_64_LINUX_HASH=$(prefetch_hash "x86_64-unknown-linux-gnu")
AARCH64_DARWIN_HASH=$(prefetch_hash "aarch64-apple-darwin")

jq -n \
  --arg version "$VERSION" \
  --arg x86_64_linux_hash "$X86_64_LINUX_HASH" \
  --arg aarch64_darwin_hash "$AARCH64_DARWIN_HASH" \
  '{
    version: $version,
    "x86_64-linux": {
      target: "x86_64-unknown-linux-gnu",
      url: "https://github.com/openai/codex/releases/download/rust-v\($version)/codex-x86_64-unknown-linux-gnu.tar.gz",
      hash: $x86_64_linux_hash
    },
    "aarch64-darwin": {
      target: "aarch64-apple-darwin",
      url: "https://github.com/openai/codex/releases/download/rust-v\($version)/codex-aarch64-apple-darwin.tar.gz",
      hash: $aarch64_darwin_hash
    }
  }' > "$SOURCES_FILE"

echo "Updated $SOURCES_FILE to version $VERSION"
