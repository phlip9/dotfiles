#!/usr/bin/env bash
# Recreate a paseo patch branch from our patch files: one commit per patch,
# applied in `patches` order from pkgs/paseo/default.nix, commit subject =
# patch file stem (export-patches.sh relies on this). A patch's tests, kept
# in pkgs/paseo/tests/<name>.patch, go into the same commit.
#
# usage: import-patches.sh <paseo-repo> <base-tag> <new-branch>
set -euo pipefail

repo=$1
base=$2
branch=$3
pkg_dir="$(git rev-parse --show-toplevel)/pkgs/paseo"

# Capture first: a failed parse must abort, not yield an empty list.
patches_list=$("$(dirname "$0")/patch-list.sh")
mapfile -t patches <<< "$patches_list"

git -C "$repo" switch --quiet --create "$branch" "$base"
for patch in "${patches[@]}"; do
  git -C "$repo" apply --index "$pkg_dir/$patch"
  if [[ -f "$pkg_dir/tests/$patch" ]]; then
    git -C "$repo" apply --index "$pkg_dir/tests/$patch"
  fi
  git -C "$repo" commit --quiet --message "${patch%.patch}"
done
git -C "$repo" log --oneline "$base..$branch"
