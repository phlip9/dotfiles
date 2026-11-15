#!/usr/bin/env bash
# Update a grafana.com plugin package's ./sources.toml w/ nixpkgs' grafana
# plugin update script.
#
# Usage: grafana-plugin-update.sh <package-dir> \
#   <nixpkgs-update-grafana-plugin.sh> <plugin-name>
#
# The nixpkgs script writes `<script dir>/<plugin-name>/sources.toml`, which
# is read-only in the nix store, so run a copy from a temp dir instead.
set -euo pipefail

package_dir="$1"
nixpkgs_script="$2"
plugin_name="$3"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cp "$nixpkgs_script" "$tmp_dir/update-grafana-plugin.sh"
bash "$tmp_dir/update-grafana-plugin.sh" "$plugin_name"
cp "$tmp_dir/$plugin_name/sources.toml" "$package_dir/sources.toml"
