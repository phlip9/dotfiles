#!/usr/bin/env nix
#!nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix --command bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.json"

# Determine current platform's target
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  CURRENT_TARGET="linux-x64" ;;
  Darwin-arm64)  CURRENT_TARGET="darwin-arm64" ;;
  *) echo "Unsupported platform" >&2; exit 1 ;;
esac

# Fetch latest binary to get version
echo "Fetching latest omnara binary..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -sL "https://releases.omnara.com/latest/omnara-${CURRENT_TARGET}" -o "$TMPDIR/omnara"
chmod +x "$TMPDIR/omnara"

# Extract version (second line of --version output)
VERSION=$("$TMPDIR/omnara" --version 2>/dev/null | tail -n1)
echo "Latest version: $VERSION"

prefetch_hash() {
  local target=$1
  local url="https://releases.omnara.com/${VERSION}/omnara-${target}"
  echo "Prefetching $target..." >&2
  nix store prefetch-file "$url" --json | jq -r '.hash'
}

LINUX_X64_HASH=$(prefetch_hash "linux-x64")
# DARWIN_ARM64_HASH=$(prefetch_hash "darwin-arm64")
# --arg darwin_arm64_hash "$DARWIN_ARM64_HASH"
# "aarch64-darwin": {
#   target: "darwin-arm64",
#   url: "https://releases.omnara.com/\($version)/omnara-darwin-arm64",
#   hash: $darwin_arm64_hash
# }

jq -n \
  --arg version "$VERSION" \
  --arg linux_x64_hash "$LINUX_X64_HASH" \
  '{
    version: $version,
    "x86_64-linux": {
      target: "linux-x64",
      url: "https://releases.omnara.com/\($version)/omnara-linux-x64",
      hash: $linux_x64_hash
    }
  }' > "$SOURCES_FILE"

echo "Updated $SOURCES_FILE to version $VERSION"
