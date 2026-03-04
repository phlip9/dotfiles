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

# Spinner for interactive progress while update scripts run.
run_with_spinner() {
  local label="$1"
  shift
  local -a cmd=( "$@" )

  if [[ ! -t 1 ]]; then
    "${cmd[@]}" >"$tmpfile" 2>&1
    return
  fi

  local -a frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
  local frame_count="${#frames[@]}"
  local frame_idx=0
  local latest_output=""
  local cols=0

  if [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]]; then
    cols="$COLUMNS"
  elif command -v tput >/dev/null 2>&1; then
    cols=$(tput cols 2>/dev/null || echo 0)
  fi

  "${cmd[@]}" >"$tmpfile" 2>&1 &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    local current_output
    current_output=$(tail -n 1 "$tmpfile" 2>/dev/null || true)
    current_output="${current_output//$'\r'/}"
    if [[ -n "$current_output" ]]; then
      latest_output="$current_output"
    fi

    local line="${frames[frame_idx]} $label"
    if [[ -n "$latest_output" ]]; then
      line+=" | $latest_output"
    fi

    if [[ "$cols" -gt 1 ]]; then
      line="${line:0:$((cols - 1))}"
    fi

    printf '\r\033[K%s' "$line"
    frame_idx=$(((frame_idx + 1) % frame_count))
    sleep 0.08
  done

  local status=0
  wait "$pid" || status=$?
  printf '\r\033[K'
  return "$status"
}

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
  if run_with_spinner "$pname: $old_version" \
    env \
      UPDATE_NIX_NAME="$name" \
      UPDATE_NIX_PNAME="$pname" \
      UPDATE_NIX_OLD_VERSION="$old_version" \
      UPDATE_NIX_ATTR_PATH="$attr_path" \
      "${cmd[@]}"
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
