#!/usr/bin/env bash
set -euo pipefail

# git-sw: `git switch` w/ an fzf branch picker when run without args.
#
# Motivation:
# - Common workflow:
#   1) `g fo` to fetch remote `origin`.
#   2) Coworker pushed `origin/them/07-24-new-feature`.
#   3) `git sw`, type a few chars, enter. Now on local `them/07-24-new-feature`
#      branch.
# - With args, behave exactly like `git switch` (ex: `git sw my-branch`).
# - Must be snappy and reliable, even in huge repos like nixpkgs
#   (~1M commits, `--filter=blob:none` partial clone).
#
# Design decisions:
# - Candidates match `git switch <Tab>`: local branches, plus remote branch
#   names eligible for DWIM (Do What I Mean) checkout (those w/o a same-named
#   local branch).
# - Initial order is by newest committer date first, like `git branch --sort`.
# - Duplicate names across multiple remotes keep only the newest for now.
# - Unlike git-cpp, no ref pruning needed. Plain ref listing and `git log <ref>`
#   previews are ~10ms even in nixpkgs, and only touch commit objects, so
#   they never trigger lazy blob fetches in partial clones.
# - Previews render on the fly in fzf. Cheap enough that caching isn't needed.

main() {
  # any args: pure `git switch` passthrough
  if [[ $# -gt 0 ]]; then
    exec git switch "$@"
  fi

  # sanity check: in git repo
  git rev-parse --is-inside-work-tree >/dev/null

  # current branch (empty if detached HEAD); excluded from candidates
  local current_branch
  current_branch="$(git branch --show-current)"

  # list all local + remote branch refs, newest committer date first
  local sep=$'\x1f'
  local ref_fmt="%(refname)$sep%(symref)$sep%(committerdate:short)$sep%(subject)"
  local all_refs
  all_refs="$(git for-each-ref --sort=-committerdate --format="$ref_fmt" \
    refs/heads refs/remotes)"

  # collect local branch names; they shadow same-named remote DWIM candidates
  local -A local_names=()
  local refname
  while IFS="$sep" read -r refname _; do
    [[ "$refname" == refs/heads/* ]] || continue
    local_names["${refname#refs/heads/}"]=1
  done <<< "$all_refs"

  # build candidate rows: (name to switch to, ref to preview, date, subject)
  local -A seen=()
  local -a names=() refs=() dates=() subjects=()
  local symref commit_date subject name max_width=0
  while IFS="$sep" read -r refname symref commit_date subject; do
    [[ -z "$refname" ]] && continue
    # skip symbolic refs like origin/HEAD
    [[ -n "$symref" ]] && continue

    if [[ "$refname" == refs/heads/* ]]; then
      name="${refname#refs/heads/}"
      # already on this branch
      [[ "$name" == "$current_branch" ]] && continue
    else
      # remote branch: DWIM name is the ref w/o the "refs/remotes/<remote>/"
      # prefix. `git switch <name>` creates a local tracking branch.
      name="${refname#refs/remotes/}"
      name="${name#*/}"
      # a same-named local branch takes precedence and is already listed
      [[ -n "${local_names[$name]:-}" ]] && continue
    fi

    # dedup same branch name across multiple remotes; keep newest
    [[ -n "${seen[$name]:-}" ]] && continue
    seen["$name"]=1

    # track max width to align output
    (( ${#name} > max_width )) && max_width=${#name}

    names+=("$name")
    refs+=("$refname")
    dates+=("$commit_date")
    subjects+=("${subject//$'\t'/  }") # sanitize subject
  done <<< "$all_refs"

  # nothing to switch to :'(
  if [[ ${#names[@]} -eq 0 ]]; then
    echo >&2 "git-sw: no branches to switch to"
    exit 1
  fi

  # open picker w/ initial order from git for-each-ref.
  # row format: <aligned display>\t<full ref>\t<switch name>
  local preview='git --no-pager log --oneline --decorate --no-merges --color=always -n 10 {2}'
  local idx selected fzf_status=0
  selected="$(
    for idx in "${!names[@]}"; do
      printf '%-*s  %s  %s\t%s\t%s\n' \
        "$max_width" "${names[$idx]}" "${dates[$idx]}" "${subjects[$idx]}" \
        "${refs[$idx]}" "${names[$idx]}"
    done | fzf --prompt='git sw> ' \
      --delimiter=$'\t' \
      --with-nth='1' \
      --nth='1' \
      --preview="$preview" \
      --preview-window='up:10:wrap' \
      --height='21' \
      --no-sort \
      --tiebreak=index
  )" || fzf_status=$?

  # 0 = ok, 1 = no match, 130 = cancelled (ESC/ctrl-c); o/w fwd fzf errors
  if [[ "$fzf_status" -ne 0 && "$fzf_status" -ne 1 && "$fzf_status" -ne 130 ]]
  then
    exit "$fzf_status"
  fi
  [[ -z "$selected" ]] && exit 0

  # switch to selected branch
  local ref branch
  ref="$(cut -f2 <<< "$selected")"
  branch="$(cut -f3 <<< "$selected")"
  if [[ "$ref" == refs/heads/* ]]; then
    exec git switch "$branch"
  fi
  # remote pick: create local tracking branch off the exact ref we previewed;
  # DWIM `git switch <name>` would error on names present in multiple remotes
  exec git switch -c "$branch" --track "$ref"
}

main "$@"
