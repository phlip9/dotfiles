#!/usr/bin/env bash
# Update ./sources.toml w/ nixpkgs' grafana plugin update script.
#
# Usage: update.sh <nixpkgs-update-grafana-plugin.sh> <plugin-name>
#
# The nixpkgs script writes `<script dir>/<plugin-name>/sources.toml`, which
# is read-only in the nix store, so run a copy from a temp dir instead.
set -euo pipefail

nixpkgs_script="$1"
plugin_name="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cp "$nixpkgs_script" "$tmp_dir/update-grafana-plugin.sh"
bash "$tmp_dir/update-grafana-plugin.sh" "$plugin_name"
cp "$tmp_dir/$plugin_name/sources.toml" "$script_dir/sources.toml"
