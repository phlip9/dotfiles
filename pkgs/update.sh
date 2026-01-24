#!/usr/bin/env bash
set -euo pipefail

packages_json="$1"

# Colors
GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

# Track results
declare -a failed_packages=()
success_count=0
total_count=$(jq 'length' "$packages_json")

# Temp file for capturing output
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Get new version after update
get_version() {
  local attr_path="$1"
  nix eval -f . --raw "phlipPkgs.$attr_path.version" 2>/dev/null || echo "?"
}

while read -r pkg; do
  name=$(echo "$pkg" | jq -r '.name')
  pname=$(echo "$pkg" | jq -r '.pname')
  old_version=$(echo "$pkg" | jq -r '.oldVersion')
  attr_path=$(echo "$pkg" | jq -r '.attrPath')

  # Build command array from JSON
  mapfile -t cmd < <(echo "$pkg" | jq -r '.updateScript[]')

  # Run update script, capturing output
  if UPDATE_NIX_NAME="$name" \
     UPDATE_NIX_PNAME="$pname" \
     UPDATE_NIX_OLD_VERSION="$old_version" \
     UPDATE_NIX_ATTR_PATH="$attr_path" \
       "${cmd[@]}" > "$tmpfile" 2>&1;
  then
    # Success - get new version and print one-liner
    new_version=$(get_version "$attr_path")
    if [[ "$old_version" == "$new_version" ]]; then
      echo "${GREEN}✓${RESET} $pname: $old_version (unchanged)"
    else
      echo "${GREEN}✓${RESET} $pname: $old_version -> $new_version"
    fi
    ((success_count++)) || true
  else
    # Failure - print full output
    echo "${RED}✗${RESET} $pname: failed"
    cat "$tmpfile"
    echo
    failed_packages+=("$pname")
  fi
done < <(jq -c '.[]' "$packages_json")

# Summary (only show if multiple packages or failures)
if [[ $total_count -gt 1 || ${#failed_packages[@]} -gt 0 ]]; then
  echo
  if [[ ${#failed_packages[@]} -eq 0 ]]; then
    echo "Updated $success_count packages"
  else
    echo "Updated $success_count packages, ${#failed_packages[@]} failed"
    echo "Failed: ${failed_packages[*]}"
  fi
fi
