#!/usr/bin/env bash
set -euo pipefail

# git-cpp: fzf picker for cherry-picking new commits from another ref.
#
# Motivation:
# - Common workflow:
#   1) `g fa` to fetch remote `agent`.
#   2) `agent/telescope-diff` branch has new commits.
#   3) Quickly cherry-pick only the missing commits onto current branch.
# - This should be snappy and reliable, even in large repos like nixpkgs.
#
# Design decisions:
# - Cheaply prune candidate refs by only considering those with a common
#   ancestor in the last 1000 commits.
# - Restrict refs to `refs/heads` and `refs/remotes` to avoid tags/other refs.
# - Show only refs that have at least one cherry-pickable commit vs HEAD.
# - Show initial candidate order by newest committer date.
# - Cache preview text once per candidate so fzf focus changes stay cheap.
# - Refuse to run during merge/rebase/cherry-pick/revert.

main() {
  # sanity check: in git repo
  git rev-parse --is-inside-work-tree >/dev/null
  local git_dir
  git_dir="$(git rev-parse --git-dir)"

  # sanity check: not mid-rebase or whatever 
  if [[ -e "$git_dir/MERGE_HEAD" ]]; then
    echo >&2 "git-cpp: merge in progress"
    exit 1
  fi
  if [[ -e "$git_dir/CHERRY_PICK_HEAD" ]]; then
    echo >&2 "git-cpp: cherry-pick in progress"
    exit 1
  fi
  if [[ -e "$git_dir/REVERT_HEAD" ]]; then
    echo >&2 "git-cpp: revert in progress"
    exit 1
  fi
  if [[ -d "$git_dir/rebase-apply" || -d "$git_dir/rebase-merge" ]]; then
    echo >&2 "git-cpp: rebase in progress"
    exit 1
  fi

  # find HEAD~1000. without using an "anchor" to prune candidates, git
  # for-each-ref takes a long time in nixpkgs
  local anchor_commit
  anchor_commit="$(git rev-list -n 1000 HEAD | tail -n 1)"
  if [[ -z "$anchor_commit" ]]; then
    echo "git-cpp: could not determine anchor commit" >&2
    exit 1
  fi

  # build tmpdir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  # get candidate refs
  local sep=$'\x1f'
  local ref_fmt="%(refname)$sep%(refname:short)$sep%(symref)$sep"
  ref_fmt+="%(committerdate:short)$sep%(subject)"
  git for-each-ref --contains="$anchor_commit" --sort=-committerdate \
    --format="$ref_fmt" refs/heads refs/remotes \
    > "$tmp_dir/candidates.tsv"

  # start background preview gen for candidates
  local -a viable_refs=()
  local refname shortref symref commit_date subject ref_id preview_file
  while IFS="$sep" read -r refname shortref symref commit_date subject; do
    [[ -n "$symref" ]] && continue

    # parallelize generation
    ref_id="${shortref//\//_}" # origin/master -> origin_master
    preview_file="$tmp_dir/$ref_id.preview"
    generate_preview_and_commits "$refname" "$preview_file" &

    viable_refs+=("$refname$sep$shortref$sep$commit_date$sep$subject$sep$ref_id")
  done < "$tmp_dir/candidates.tsv"

  # wait for all previews to generate
  wait

  # build final picker rows
  local -a meta_lines=()
  local max_width=0 display_line
  for entry in "${viable_refs[@]}"; do
    IFS="$sep" read -r refname shortref commit_date subject ref_id <<< "$entry"

    # skip candidates that have nothing to cherry-pick
    preview_file="$tmp_dir/$ref_id.preview"
    [[ ! -s "$preview_file" ]] && continue

    # track max width to align output
    (( ${#shortref} > max_width )) && max_width=${#shortref}

    # sanitize subject
    subject="${subject//$'\t'/  }"

    meta_lines+=("$shortref$sep$commit_date$sep$subject$sep$ref_id")
  done

  # nothing to cherry-pick :'(
  if [[ ${#meta_lines[@]} -eq 0 ]]; then
    echo >&2 "git-cpp: no reachable refs with cherry-pickable commits"
    exit 1
  fi

  # build aligned display lines
  local picker_rows="$tmp_dir/picker.tsv"
  for line in "${meta_lines[@]}"; do
    IFS="$sep" read -r short_ref commit_date subject ref_id <<< "$line"
    printf -v display_line '%-*s  %s  %s' "$max_width" "$short_ref" "$commit_date" "$subject"
    printf '%s\t%s\n' "$display_line" "$ref_id" >> "$picker_rows"
  done

  # open picker w/ initial order from git for-each-ref
  local selected
  selected="$(
    fzf --prompt='git cpp> ' \
      --delimiter=$'\t' \
      --nth='1' \
      --preview="cat $tmp_dir/{2}.preview" \
      --preview-window='up:10:wrap' \
      --height='21' \
      --no-sort \
      --tiebreak=index \
      < "${picker_rows}"
  )"
  [[ -z "$selected" ]] && exit 0

  # pull out selected commits to cherry-pick
  local selected_id
  selected_id="$(printf '%s' "$selected" | cut -f2)"
  local selected_preview="$tmp_dir/$selected_id.preview"
  mapfile -t commits < <(cut -d' ' -f1 "$selected_preview")
  if [[ ${#commits[@]} -eq 0 ]]; then
    echo >&2 "git-cpp: selected ref has no cherry-pickable commits"
    exit 1
  fi

  git cherry-pick "${commits[@]}"
}

# helper to generate _.preview file
generate_preview_and_commits() {
  local refname="$1" preview_file="$2"
  git --no-pager log --reverse --oneline --no-merges \
      --cherry-pick --right-only --decorate \
      "HEAD...$refname" > "$preview_file"
}

main "$@"
