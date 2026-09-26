#!/usr/bin/env bash
set -euo pipefail

# system-diff.sh: show generated-config changes between two built NixOS
# systems, e.g. before and after a nixpkgs bump.
#
# Usage: system-diff.sh <old-toplevel> <new-toplevel>
#
# Complements `nix store diff-closures` (package versions). Surfaces module
# behavior changes that release notes often omit: changed defaults, unit
# ordering/hardening, generated config files, script flags.
#
# Compares:
# - toplevel text files (activate, kernel-params, ...)
# - etc/ files added/removed/changed. Unit enablement symlinks (*.wants/,
#   *.requires/, *.upholds/) compare by name only. Binary or large files
#   compare by size only.
# - small generated store files referenced from the above (unit scripts,
#   config files), up to 2 levels deep
#
# Store hashes and package versions are masked so only real changes remain.
# File handling is batched (one grep/cp/sed per phase), since a system has
# ~6k etc/ files.

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <old-toplevel> <new-toplevel>" >&2
  exit 2
fi

old=$(readlink -f "$1")
new=$(readlink -f "$2")

# Max size of a text file we'll dump.
max_file_kib=256
# Max NAR size of a referenced store path we'll follow. Keeps us to generated
# files/scripts and out of real packages.
max_ref_bytes=$((256 * 1024))

store_re='/nix/store/[a-z0-9]{32}-[^ "'\''=:;,()<>`]+'

# sed args masking store hashes and package versions:
#   /nix/store/<hash>-glibc-locales-2.42-67/lib -> <store>/glibc-locales/lib
mask_sed=(
  -E
  -e 's|/nix/store/[a-z0-9]{32}-|<store>/|g'
  -e 's|(<store>/[A-Za-z_+.][A-Za-z0-9_+.]*(-[A-Za-z_+.][A-Za-z0-9_+.]*)*)-[0-9][A-Za-z0-9_+.-]*|\1|g'
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Is $1 a text file inside a small, generated store path? Rejects refs that
# resolve outside their own store path (symlink farms like system-path/etc)
# and refs into big store paths (real packages).
declare -A root_bytes=()
is_generated_text() {
  local ref="$1" root real
  root="${ref#/nix/store/}"
  root="/nix/store/${root%%/*}"
  [[ -e "$root" ]] || return 1

  real=$(readlink -f "$ref")
  [[ "$real" == "$root" || "$real" == "$root"/* ]] || return 1
  [[ -f "$real" ]] || return 1

  # NAR size from the store db; much faster than walking packages w/ du
  if [[ -z "${root_bytes[$root]:-}" ]]; then
    root_bytes[$root]=$(nix-store --query --size "$root" 2>/dev/null || echo 0)
  fi
  [[ "${root_bytes[$root]}" -le $max_ref_bytes ]] || return 1

  grep -Iq . "$real" 2>/dev/null
}

# Dump one system into a masked, flattened tree under $2:
#   $2/toplevel/<file>, $2/etc/<path>, $2/refs/<masked-store-path>
dump_system() {
  local system="$1" out="$2"
  local etc="$system/etc"
  local all="$tmp/all" text="$tmp/text"
  local -A seen=() is_text=()
  local dumped=() next=()
  local file rel size ref key _level

  mkdir -p "$out/toplevel" "$out/etc" "$out/refs"

  # toplevel text files
  for file in "$system"/*; do
    if [[ -f "$file" ]] && grep -Iq . "$file" 2>/dev/null; then
      cp -L --no-preserve=mode "$file" "$out/toplevel/"
      dumped+=("$file")
      seen[$file]=1
    fi
  done

  # etc/: list all files w/ sizes, then find the small text files in one grep
  (cd "$etc" && find -L . -type f -printf '%P\t%s\n' 2>/dev/null) >"$all"
  (cd "$etc" && find -L . -type f -size -"$max_file_kib"k \
    -not -regex '.*\.\(wants\|requires\|upholds\)/.*' -printf '%P\0' \
    2>/dev/null | xargs -0r grep -IlZ '' --) >"$text"

  # copy text files, preserving relative paths
  (cd "$etc" &&
    xargs -0r cp -L --parents --no-preserve=mode -t "$out/etc" <"$text")
  while IFS= read -r -d '' rel; do
    is_text[$rel]=1
    dumped+=("$etc/$rel")
    # don't dump the same store file again as a ref
    seen[$(readlink -f "$etc/$rel")]=1
  done <"$text"

  # everything else: enablement symlinks by name, binary/large by size
  while IFS=$'\t' read -r rel size; do
    [[ -n "${is_text[$rel]:-}" ]] && continue
    mkdir -p "$out/etc/$(dirname "$rel")"
    if [[ "$rel" =~ \.(wants|requires|upholds)/ ]]; then
      : >"$out/etc/$rel"
    else
      echo "<binary or large: $size bytes>" >"$out/etc/$rel"
    fi
  done <"$all"

  # follow small generated store files referenced from dumped files, 2 levels
  for _level in 1 2; do
    next=()
    while IFS= read -r ref; do
      [[ -n "${seen[$ref]:-}" ]] && continue
      seen[$ref]=1
      is_generated_text "$ref" || continue
      key=$(sed "${mask_sed[@]}" -e 's|^<store>/||' <<<"$ref")
      cp -L --no-preserve=mode "$ref" "$out/refs/${key//\//__}"
      next+=("$ref")
    done < <(printf '%s\0' "${dumped[@]}" |
      xargs -0r grep -ohE "$store_re" -- 2>/dev/null | sort -u)
    [[ ${#next[@]} -gt 0 ]] || break
    dumped=("${next[@]}")
  done

  # mask everything we copied, in one batch
  find "$out" -type f -size +0 -print0 | xargs -0r sed -i "${mask_sed[@]}"
}

dump_system "$old" "$tmp/old"
dump_system "$new" "$tmp/new"

# drop mtimes from file headers
cd "$tmp"
{ diff -ru -U2 old new || true; } | sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*/\1 \2/'
