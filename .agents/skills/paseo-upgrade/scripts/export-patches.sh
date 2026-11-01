#!/usr/bin/env bash
# Write each commit in <base-tag>..<rev> of a paseo patch branch to
# pkgs/paseo/<commit subject>.patch, then list patch files to add to or
# remove from pkgs/paseo/default.nix.
#
# Test files (*.test.ts(x), *.spec.ts(x), e2e/, vitest.config.*) go to a
# separate pkgs/paseo/tests/<name>.patch: upstream's nix src filter strips
# test files, so the package build can't apply them. import-patches.sh
# re-applies both.
#
# Patches that differ only in `index <blob>..<blob>` lines are left alone, so
# re-exporting an unchanged stack is a no-op.
#
# --check: write nothing; exit 1 if pkgs/paseo differs from the branch.
#
# usage: export-patches.sh [--check] <paseo-repo> <base-tag> [<rev>]
set -euo pipefail

check=0
if [[ ${1:-} == --check ]]; then
  check=1
  shift
fi
repo=$1
base=$2
rev=${3:-HEAD}
pkg_dir="$(git rev-parse --show-toplevel)/pkgs/paseo"

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/tests"

test_paths=(
  ':(glob)**/*.test.ts'
  ':(glob)**/*.test.tsx'
  ':(glob)**/*.spec.ts'
  ':(glob)**/*.spec.tsx'
  ':(glob)**/e2e/**'
  ':(glob)**/vitest.config.*'
)
non_test_paths=(.)
for path in "${test_paths[@]}"; do
  non_test_paths+=(":(exclude,${path#:(}")
done

diff_commit() {
  git -C "$repo" diff --no-color --no-ext-diff "$1^" "$1" -- "${@:2}"
}

# Render every commit into $out.
mapfile -t commits < <(git -C "$repo" rev-list --reverse "$base..$rev")
exported=()
for commit in "${commits[@]}"; do
  name=$(git -C "$repo" log -1 --format=%s "$commit")
  if [[ ! $name =~ ^paseo-[a-z0-9-]+$ ]]; then
    echo "error: commit $commit subject must be a patch name: $name" >&2
    exit 1
  fi
  diff_commit "$commit" "${non_test_paths[@]}" > "$out/$name.patch"
  if [[ ! -s "$out/$name.patch" ]]; then
    echo "error: $name has no non-test changes" >&2
    exit 1
  fi
  diff_commit "$commit" "${test_paths[@]}" > "$out/tests/$name.patch"
  [[ -s "$out/tests/$name.patch" ]] || rm "$out/tests/$name.patch"
  exported+=("$name.patch")
done

# Same patch modulo `index` lines (blob hashes shift w/ unrelated history).
same_patch() {
  diff -q <(grep -v '^index ' "$1") <(grep -v '^index ' "$2") > /dev/null
}

# Sync $out -> pkgs/paseo, reporting every difference.
shopt -s nullglob
changed=0
for path in "$out"/*.patch "$out"/tests/*.patch; do
  rel=${path#"$out"/}
  dest="$pkg_dir/$rel"
  if [[ -f $dest ]] && same_patch "$path" "$dest"; then
    continue
  fi
  changed=1
  if ((check)); then
    echo "differs: $rel"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$path" "$dest"
    echo "wrote: $rel"
  fi
done
for dest in "$pkg_dir"/*.patch "$pkg_dir"/tests/*.patch; do
  rel=${dest#"$pkg_dir"/}
  if [[ ! -f "$out/$rel" ]]; then
    changed=1
    echo "not on branch, remove: $rel"
  fi
done

# Patch list drift: the active default.nix `patches` list must name exactly
# the branch's patches, in branch order (import applies them in that order).
# Capture first: a failed parse must abort, not yield an empty list.
active_list=$("$(dirname "$0")/patch-list.sh")
mapfile -t active <<< "$active_list"
for patch in "${exported[@]}"; do
  if [[ " ${active[*]} " != *" $patch "* ]]; then
    changed=1
    echo "add to default.nix: $patch"
  fi
done
for patch in "${active[@]}"; do
  if [[ " ${exported[*]} " != *" $patch "* ]]; then
    changed=1
    echo "not on branch, remove from default.nix: $patch"
  fi
done
if [[ "${active[*]}" != "${exported[*]}" ]]; then
  changed=1
  echo "default.nix patch order differs from branch:"
  echo "  default.nix: ${active[*]}"
  echo "  branch:      ${exported[*]}"
fi

if ((check && changed)); then
  exit 1
fi
