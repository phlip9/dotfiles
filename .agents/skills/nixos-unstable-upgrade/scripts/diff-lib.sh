#!/usr/bin/env bash
# Shared helpers for retaining files whose paths collide after masking.

# Save each distinct masked text under its content hash, removing duplicates.
# Remaining args are passed to sed, e.g. the caller's mask_sed array.
add_masked_fragment() {
  local input="$1" parts_dir="$2" digest
  shift 2
  mkdir -p "$parts_dir"
  sed "$@" "$input" >"$parts_dir/.fragment"
  digest=$(sha256sum "$parts_dir/.fragment")
  mv "$parts_dir/.fragment" "$parts_dir/${digest%% *}"
}

# Join colliding files in content order so store-hash churn cannot reorder
# them. Single files retain their original layout for readable diffs.
join_masked_fragments() {
  local parts_dir="$1" output="$2" fragment content
  local fragments=()
  for fragment in "$parts_dir"/*; do
    [[ -f "$fragment" ]] && fragments+=("$fragment")
  done
  mkdir -p "$(dirname "$output")"
  if [[ ${#fragments[@]} -eq 1 ]]; then
    cp "${fragments[0]}" "$output"
    return
  fi

  # NUL delimiters preserve whole multiline files while sorting.
  {
    for fragment in "${fragments[@]}"; do
      cat "$fragment"
      printf '\0'
    done
  } | LC_ALL=C sort -z |
    while IFS= read -r -d '' content; do
      printf '# --- masked file ---\n%s\n' "$content"
    done >"$output"
}
