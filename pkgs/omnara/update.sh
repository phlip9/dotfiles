#!/usr/bin/env nix
#!nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix nixpkgs#ripgrep --command bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.json"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Extract version from binary using strings (works cross-platform)
extract_version() {
  local binary=$1
  strings "$binary" \
    | rg -om1 '"([0-9]+\.[0-9]+\.[0-9]+)",.*"Command-line interface for Omnara."' -r '$1'
}

# Fetch latest binary, extract version, prefetch versioned URL
update_platform() {
  local nix_system=$1
  local target=$2

  echo "Updating $nix_system ($target)..." >&2

  # Fetch latest binary
  local latest_url="https://releases.omnara.com/latest/omnara-${target}"
  curl -sL "$latest_url" -o "$TMPDIR/omnara-${target}"

  # Extract version from binary
  local version
  version=$(extract_version "$TMPDIR/omnara-${target}") || true
  if [[ -z "$version" ]]; then
    echo "  error: failed to extract version from binary" >&2
    return 1
  fi
  echo "  version: $version" >&2

  # Prefetch versioned URL to get hash
  local versioned_url="https://releases.omnara.com/${version}/omnara-${target}"
  local hash
  hash=$(nix store prefetch-file "$versioned_url" --json | jq -r '.hash')
  echo "  hash: $hash" >&2

  # Output JSON fragment
  jq -n \
    --arg version "$version" \
    --arg target "$target" \
    --arg url "$versioned_url" \
    --arg hash "$hash" \
    '{
      version: $version,
      target: $target,
      url: $url,
      hash: $hash
    }'
}

LINUX_X64=$(update_platform "x86_64-linux" "linux-x64")
DARWIN_ARM64=$(update_platform "aarch64-darwin" "darwin-arm64")

jq -n \
  --argjson linux_x64 "$LINUX_X64" \
  --argjson darwin_arm64 "$DARWIN_ARM64" \
  '{
    "x86_64-linux": $linux_x64,
    "aarch64-darwin": $darwin_arm64
  }' > "$SOURCES_FILE"

echo "Updated $SOURCES_FILE"
