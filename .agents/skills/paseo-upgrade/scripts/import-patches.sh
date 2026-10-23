#!/usr/bin/env bash
# Recreate a paseo patch branch from our patch files: one commit per patch,
# applied in `patches` order from pkgs/paseo/default.nix, commit subject =
# patch file stem (export-patches.sh relies on this).
#
# usage: import-patches.sh <paseo-repo> <base-tag> <new-branch>
set -euo pipefail

repo=$1
base=$2
branch=$3
pkg_dir="$(git rev-parse --show-toplevel)/pkgs/paseo"

mapfile -t patches < <(
  grep -oP '^\s*\./\K[\w.-]+\.patch' "$pkg_dir/default.nix"
)

git -C "$repo" switch --quiet --create "$branch" "$base"
for patch in "${patches[@]}"; do
  git -C "$repo" apply --index "$pkg_dir/$patch"
  git -C "$repo" commit --quiet --message "${patch%.patch}"
done
git -C "$repo" log --oneline "$base..$branch"
