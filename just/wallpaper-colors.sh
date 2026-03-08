#!/usr/bin/env bash
set -euo pipefail

wallpaper_name="${1:-default}"
repo_root="$PWD"

build_out=$(
  nix build -f . --no-link --print-out-paths \
    "wallpapers.${wallpaper_name}.configs"
)

if [[ ! -d "$build_out/config" ]]; then
  echo "missing generated config dir: $build_out/config" >&2
  exit 1
fi

# Copy the generated config payload into the repo config/ tree.
fd . \
  --base-directory "$build_out/config" \
  --strip-cwd-prefix=always \
  --type file \
  --exec bash -c \
  "install -D --mode=0644 -- \"\$1\" \"\$2/config/\$1\"" \
  bash {} "$repo_root"
