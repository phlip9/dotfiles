#!/usr/bin/env bash
set -euo pipefail

packages_json="$1"

echo "Packages to update:"
jq -r '.[].name' "$packages_json"
echo

jq -c '.[]' "$packages_json" | while read -r pkg; do
  name=$(echo "$pkg" | jq -r '.name')
  pname=$(echo "$pkg" | jq -r '.pname')
  old_version=$(echo "$pkg" | jq -r '.oldVersion')
  attr_path=$(echo "$pkg" | jq -r '.attrPath')

  echo "=== Updating $name ==="

  # Build command array from JSON
  mapfile -t cmd < <(echo "$pkg" | jq -r '.updateScript[]')

  # Run with environment variables set
  UPDATE_NIX_NAME="$name" \
  UPDATE_NIX_PNAME="$pname" \
  UPDATE_NIX_OLD_VERSION="$old_version" \
  UPDATE_NIX_ATTR_PATH="$attr_path" \
    "${cmd[@]}" || echo "ERROR: Failed to update $name"

  echo
done

echo "Done!"
