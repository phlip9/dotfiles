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

# Prefetch one platform-specific release artifact and print its Nix hash.
prefetch_hash() {
  local artifact=$1
  local target=$2
  local url="https://github.com/openai/codex/releases/download/rust-v${VERSION}/${artifact}-${target}.zst"
  echo "Prefetching $artifact for $target..." >&2
  nix store prefetch-file "$url" --json | jq -r '.hash'
}

X86_64_LINUX_CODEX_HASH=$(
  prefetch_hash codex "x86_64-unknown-linux-musl"
)
X86_64_LINUX_CODE_MODE_HOST_HASH=$(
  prefetch_hash codex-code-mode-host "x86_64-unknown-linux-musl"
)
AARCH64_DARWIN_CODEX_HASH=$(
  prefetch_hash codex "aarch64-apple-darwin"
)
AARCH64_DARWIN_CODE_MODE_HOST_HASH=$(
  prefetch_hash codex-code-mode-host "aarch64-apple-darwin"
)

jq -n \
  --arg version "$VERSION" \
  --arg base_url \
    "https://github.com/openai/codex/releases/download/rust-v${VERSION}" \
  --arg x86_64_linux_codex_hash "$X86_64_LINUX_CODEX_HASH" \
  --arg x86_64_linux_code_mode_host_hash \
    "$X86_64_LINUX_CODE_MODE_HOST_HASH" \
  --arg aarch64_darwin_codex_hash "$AARCH64_DARWIN_CODEX_HASH" \
  --arg aarch64_darwin_code_mode_host_hash \
    "$AARCH64_DARWIN_CODE_MODE_HOST_HASH" \
  '{
    version: $version,
    "x86_64-linux": {
      codex: {
        url: "\($base_url)/codex-x86_64-unknown-linux-musl.zst",
        hash: $x86_64_linux_codex_hash
      },
      codeModeHost: {
        url: "\($base_url)/codex-code-mode-host-x86_64-unknown-linux-musl.zst",
        hash: $x86_64_linux_code_mode_host_hash
      }
    },
    "aarch64-darwin": {
      codex: {
        url: "\($base_url)/codex-aarch64-apple-darwin.zst",
        hash: $aarch64_darwin_codex_hash
      },
      codeModeHost: {
        url: "\($base_url)/codex-code-mode-host-aarch64-apple-darwin.zst",
        hash: $aarch64_darwin_code_mode_host_hash
      }
    }
  }' > "$SOURCES_FILE"

echo "Updated $SOURCES_FILE to version $VERSION"
