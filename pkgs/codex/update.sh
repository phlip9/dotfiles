#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.json"

# Fetch latest version from GitHub releases API
echo "Fetching latest codex version..."
LATEST_TAG=$(curl -fsSL \
  "https://api.github.com/repos/openai/codex/releases/latest" \
  | jq -er '.tag_name')
VERSION="${LATEST_TAG#rust-v}"
echo "Latest version: $VERSION"

BASE_URL="https://github.com/openai/codex/releases/download/rust-v${VERSION}"

# Prefetch one release artifact and print its Nix hash.
prefetch_hash() {
  local url=$1
  echo "Prefetching $url..." >&2
  nix store prefetch-file "$url" --json | jq -r '.hash'
}

# Print the sources.json entry for one rust target's release artifacts.
platform_sources() {
  local target=$1
  local codex_url="$BASE_URL/codex-${target}.zst"
  local code_mode_host_url="$BASE_URL/codex-code-mode-host-${target}.zst"
  local codex_hash code_mode_host_hash
  codex_hash=$(prefetch_hash "$codex_url")
  code_mode_host_hash=$(prefetch_hash "$code_mode_host_url")
  jq -n \
    --arg target "$target" \
    --arg codex_url "$codex_url" \
    --arg codex_hash "$codex_hash" \
    --arg code_mode_host_url "$code_mode_host_url" \
    --arg code_mode_host_hash "$code_mode_host_hash" \
    '{
      target: $target,
      codex: { url: $codex_url, hash: $codex_hash },
      codeModeHost: { url: $code_mode_host_url, hash: $code_mode_host_hash }
    }'
}

X86_64_LINUX=$(platform_sources "x86_64-unknown-linux-musl")
AARCH64_DARWIN=$(platform_sources "aarch64-apple-darwin")

jq -n \
  --arg version "$VERSION" \
  --argjson x86_64_linux "$X86_64_LINUX" \
  --argjson aarch64_darwin "$AARCH64_DARWIN" \
  '{
    version: $version,
    "x86_64-linux": $x86_64_linux,
    "aarch64-darwin": $aarch64_darwin
  }' > "$SOURCES_FILE"

echo "Updated $SOURCES_FILE to version $VERSION"
