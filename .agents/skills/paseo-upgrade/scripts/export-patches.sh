#!/usr/bin/env bash
# Write each commit in <base-tag>..<rev> of a paseo patch branch to
# pkgs/paseo/<commit subject>.patch, then list patch files to add to or
# remove from pkgs/paseo/default.nix.
#
# usage: export-patches.sh <paseo-repo> <base-tag> [<rev>]
set -euo pipefail

repo=$1
base=$2
rev=${3:-HEAD}
pkg_dir="$(git rev-parse --show-toplevel)/pkgs/paseo"

mapfile -t commits < <(git -C "$repo" rev-list --reverse "$base..$rev")
exported=()
for commit in "${commits[@]}"; do
  name=$(git -C "$repo" log -1 --format=%s "$commit")
  if [[ ! $name =~ ^paseo-[a-z0-9-]+$ ]]; then
    echo "error: commit $commit subject must be a patch name: $name" >&2
    exit 1
  fi
  git -C "$repo" diff --no-color --no-ext-diff "$commit^" "$commit" \
    > "$pkg_dir/$name.patch"
  exported+=("$name.patch")
done

# Patch list drift: new patches need a default.nix entry, dropped patches
# need their file and entry removed.
for patch in "${exported[@]}"; do
  grep -q "\./$patch" "$pkg_dir/default.nix" \
    || echo "add to default.nix: $patch"
done
for path in "$pkg_dir"/*.patch; do
  patch=$(basename "$path")
  [[ " ${exported[*]} " == *" $patch "* ]] || echo "dropped, remove: $patch"
done
