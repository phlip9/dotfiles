#!/usr/bin/env bash
set -euo pipefail

# initrd-diff.sh: show initrd content changes between two built NixOS
# systems, e.g. before and after a nixpkgs bump.
#
# Usage: initrd-diff.sh <old-toplevel> <new-toplevel>
#
# Complements system-diff.sh, which doesn't look inside the initrd. Matters
# for boot-critical changes (LUKS unlock, udev rules, initrd units), esp. on
# remote machines.
#
# Compares:
# - file list (names only; kernel module sizes churn on every rebuild)
# - contents of small text files (units, udev rules, generated config)
#
# Store hashes and package versions are masked so only real changes remain.
# Needs cpio, zstd, xz, gzip in PATH, e.g.:
#   nix shell -f . pkgs.cpio pkgs.zstd pkgs.xz pkgs.gzip --command \
#     initrd-diff.sh <old> <new>

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <old-toplevel> <new-toplevel>" >&2
  exit 2
fi

# Max size of a text file we'll diff.
max_file_kib=256

mask_sed=(
  -E
  -e 's|/nix/store/[a-z0-9]{32}-|<store>/|g'
  -e 's|(<store>/[A-Za-z_+.][A-Za-z0-9_+.]*(-[A-Za-z_+.][A-Za-z0-9_+.]*)*)-[0-9][A-Za-z0-9_+.-]*|\1|g'
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Unpack the main initrd archive into $2. NixOS prepends an uncompressed
# early cpio (CPU microcode) before the compressed main archive, so skip to
# the first compression magic. Fall back to a plain cpio.
extract() {
  local initrd="$1" out="$2" offset=""
  local -A magics=(
    [zstd]='\x28\xb5\x2f\xfd'
    [xz]='\xfd\x37\x7a\x58\x5a\x00'
    [gzip]='\x1f\x8b\x08'
  )
  local -A decompress=([zstd]="zstd -dc" [xz]="xz -dc" [gzip]="gzip -dc")
  local format found best_format=""

  for format in "${!magics[@]}"; do
    found=$(LC_ALL=C grep -obUaP -m1 "${magics[$format]}" "$initrd" |
      head -1 | cut -d: -f1 || true)
    if [[ -n "$found" ]] && [[ -z "$offset" || "$found" -lt "$offset" ]]; then
      offset="$found"
      best_format="$format"
    fi
  done

  mkdir -p "$out"
  if [[ -z "$best_format" ]]; then
    (cd "$out" && cpio -idm --quiet --no-absolute-filenames <"$initrd")
  else
    tail -c +$((offset + 1)) "$initrd" | ${decompress[$best_format]} |
      (cd "$out" && cpio -idm --quiet --no-absolute-filenames)
  fi
}

# Dump one unpacked initrd into a masked tree under $2:
#   $2/files.list, $2/text/<masked-path>
dump() {
  local root="$1" out="$2" rel key

  mkdir -p "$out/text"
  (cd "$root" && find . \( -type f -o -type l \) -printf '/%P\n') |
    sed "${mask_sed[@]}" | sort >"$out/files.list"

  while IFS= read -r -d '' rel; do
    key=$(sed "${mask_sed[@]}" <<<"/$rel")
    mkdir -p "$out/text/$(dirname "$key")"
    sed "${mask_sed[@]}" "$root/$rel" >"$out/text/$key"
  done < <(cd "$root" && find . -type f -size -"$max_file_kib"k \
    -not -name '*.ko*' -printf '%P\0' | xargs -0r grep -IlZ '' --)
}

for side in old:"$1" new:"$2"; do
  name="${side%%:*}"
  system=$(readlink -f "${side#*:}")
  extract "$(readlink -f "$system/initrd")" "$tmp/raw-$name"
  dump "$tmp/raw-$name" "$tmp/$name"
done

cd "$tmp"
{ diff -u old/files.list new/files.list || true; } |
  sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*/\1 \2/'
{ diff -ru -U2 old/text new/text || true; } |
  sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*/\1 \2/'
