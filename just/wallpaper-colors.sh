#!/usr/bin/env bash
set -euo pipefail

wallpaper_name="${1:-default}"

build_out=$(
  nix build -f . --no-link --print-out-paths \
    "wallpapers.${wallpaper_name}.configs"
)

if [[ ! -d "$build_out/config" ]]; then
  echo "missing generated config dir: $build_out/config" >&2
  exit 1
fi

# Copy the generated configs into the repo
fd . \
  --base-directory "$build_out/config" \
  --strip-cwd-prefix=always \
  --type file \
  --exec install -D --mode=0644 -- "{}" "$PWD/config/{}"
