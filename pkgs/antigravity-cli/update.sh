#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://storage.googleapis.com/antigravity-public/antigravity-cli"
VERSION="$(curl -fsSL "$BASE_URL/latest")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="$SCRIPT_DIR/manifest.json"

# Upstream's manifest pins each platform's tarball url + sha512, so no
# prefetching. Reformat via jq, which also rejects a truncated or non-JSON
# resp before it can clobber manifest.json.
MANIFEST="$(curl -fsSL "$BASE_URL/$VERSION/manifest.json" | jq -e .)"
printf '%s\n' "$MANIFEST" > "$MANIFEST_FILE"
