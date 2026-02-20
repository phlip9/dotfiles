#!/usr/bin/env bash
set -euo pipefail

# substituted in nix derivation
readonly gh="@gh@"
readonly git="@git@"
readonly github_agent_token="@githubAgentToken@"

usage() {
  cat >&2 <<'USAGE'
usage: github-agent-gh [gh args...]

Wrapper around gh that injects GH_TOKEN from github-agent-authd.

Repo resolution order:
  1. explicit --repo/-R argument
  2. current git remote

--- original unwrapped gh ---

USAGE
}

fail() {
  echo "$*" >&2
  exit 1
}

# Validate OWNER/REPO and normalize HOST/OWNER/REPO -> OWNER/REPO.
normalize_repo_arg() {
  local input="$1"

  if [[ -z "$input" ]]; then
    return 1
  fi

  if [[ "$input" == */*/* ]]; then
    local host=${input%%/*}
    local rest=${input#*/}

    if [[ "$host" != "github.com" ]]; then
      return 1
    fi

    input="$rest"
  fi

  if [[ "$input" != */* ]]; then
    return 1
  fi

  local owner=${input%%/*}
  local repo=${input#*/}
  if [[ -z "$owner" || -z "$repo" || "$repo" == */* ]]; then
    return 1
  fi

  printf '%s/%s\n' "$owner" "$repo"
}

# Parse OWNER/REPO from common github.com git remote URL forms.
parse_owner_repo_from_remote_url() {
  local remote_url="$1"
  local path=""

  case "$remote_url" in
    https://github.com/*)
      path=${remote_url#https://github.com/}
      ;;
    http://github.com/*)
      path=${remote_url#http://github.com/}
      ;;
    git@github.com:*)
      path=${remote_url#git@github.com:}
      ;;
    ssh://git@github.com/*)
      path=${remote_url#ssh://git@github.com/}
      ;;
    ssh://github.com/*)
      path=${remote_url#ssh://github.com/}
      ;;
    *)
      return 1
      ;;
  esac

  path=${path%.git}
  path=${path%%\?*}
  path=${path%%#*}
  path=${path#/}

  normalize_repo_arg "$path"
}

# Derive OWNER/REPO from current repository's configured remote.
detect_repo_from_git() {
  if ! "$git" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi

  local remote_name=""
  local remote_url=""
  local upstream

  upstream="$($git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' \
    2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    remote_name=${upstream%%/*}
  fi

  if [[ -n "$remote_name" ]]; then
    remote_url="$($git config --get "remote.${remote_name}.url" \
      2>/dev/null || true)"
  fi

  if [[ -z "$remote_url" ]]; then
    remote_url="$($git config --get remote.origin.url 2>/dev/null || true)"
  fi

  if [[ -z "$remote_url" ]]; then
    local remotes=()
    mapfile -t remotes < <($git remote 2>/dev/null)
    if [[ ${#remotes[@]} -gt 0 ]]; then
      remote_name=${remotes[0]}
      remote_url="$($git config --get "remote.${remote_name}.url" \
        2>/dev/null || true)"
    fi
  fi

  if [[ -z "$remote_url" ]]; then
    return 1
  fi

  parse_owner_repo_from_remote_url "$remote_url"
}

args=("$@")
gh_args=()
repo_arg=""
show_help=0
index=0
while ((index < ${#args[@]})); do
  arg=${args[$index]}
  case "$arg" in
    --repo)
      if ((index + 1 >= ${#args[@]})); then
        fail "missing value for --repo"
      fi
      repo_arg=${args[$((index + 1))]}
      ((index += 2))
      continue
      ;;
    --repo=*)
      repo_arg=${arg#--repo=}
      ((index += 1))
      continue
      ;;
    -R)
      if ((index + 1 >= ${#args[@]})); then
        fail "missing value for -R"
      fi
      repo_arg=${args[$((index + 1))]}
      ((index += 2))
      continue
      ;;
    -R*)
      repo_arg=${arg#-R}
      ((index += 1))
      continue
      ;;
    -h|--help)
      show_help=1
      ;;
  esac

  gh_args+=("$arg")
  ((index += 1))
done

if ((show_help)); then
  usage
  exec "$gh" "${gh_args[@]}"
fi

owner_repo=""
if [[ -n "$repo_arg" ]]; then
  if ! owner_repo=$(normalize_repo_arg "$repo_arg"); then
    fail "invalid --repo/-R value; expected OWNER/REPO or github.com/OWNER/REPO"
  fi
else
  if ! owner_repo=$(detect_repo_from_git); then
    fail "cannot determine repository; pass --repo OWNER/REPO"
  fi
fi

# github-agent-token emits actionable errors; forward exit status unchanged.
if ! token="$($github_agent_token --repo "$owner_repo")"; then
  exit $?
fi

export GH_TOKEN="$token"

# Only forward --repo when the caller explicitly provided it. When the repo was
# auto-detected from git, gh can do its own remote detection and not all
# subcommands accept --repo (e.g., `gh help`).
if [[ -n "$repo_arg" ]]; then
  exec "$gh" --repo "$owner_repo" "${gh_args[@]}"
else
  exec "$gh" "${gh_args[@]}"
fi
