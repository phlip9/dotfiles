#!/usr/bin/env bash
set -euo pipefail

# substituted in nix derivation
readonly github_agent_token="@githubAgentToken@"

usage() {
  cat >&2 <<'USAGE'
usage: github-agent-git-credential-helper [get|store|erase]

Git credential helper for https://github.com URLs.
USAGE
}

# Parse OWNER/REPO from a credential path value.
parse_owner_repo_from_path() {
  local raw_path="$1"
  raw_path=${raw_path#/}
  raw_path=${raw_path%.git}

  if [[ "$raw_path" != */* ]]; then
    return 1
  fi

  local owner=${raw_path%%/*}
  local repo=${raw_path#*/}
  if [[ -z "$owner" || -z "$repo" || "$repo" == */* ]]; then
    return 1
  fi

  printf '%s/%s\n' "$owner" "$repo"
}

# Parse OWNER/REPO from a full GitHub URL if `path` is absent.
parse_owner_repo_from_url() {
  local url="$1"
  if [[ "$url" != https://github.com/* ]]; then
    return 1
  fi

  parse_owner_repo_from_path "${url#https://github.com/}"
}

operation="${1:-get}"
case "$operation" in
  get)
    ;;
  store|erase)
    # No-op for non-read operations.
    exit 0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac

protocol=""
host=""
path=""
url=""
while IFS= read -r line; do
  [[ -z "$line" ]] && break

  key=${line%%=*}
  value=${line#*=}

  case "$key" in
    protocol)
      protocol="$value"
      ;;
    host)
      host="$value"
      ;;
    path)
      path="$value"
      ;;
    url)
      url="$value"
      ;;
  esac
done

# Only handle github.com HTTPS credentials.
if [[ -n "$protocol" && "$protocol" != "https" ]]; then
  exit 0
fi
if [[ "$host" != "github.com" ]]; then
  exit 0
fi

owner_repo=""
if [[ -n "$path" ]]; then
  if ! owner_repo=$(parse_owner_repo_from_path "$path"); then
    exit 0
  fi
elif [[ -n "$url" ]]; then
  if ! owner_repo=$(parse_owner_repo_from_url "$url"); then
    exit 0
  fi
else
  exit 0
fi

# Unknown installation is treated as a clean miss so git can fallback.
if ! token="$($github_agent_token --repo "$owner_repo" 2>/dev/null)"; then
  token_exit_code=$?
  if [[ "$token_exit_code" -eq 10 ]]; then
    exit 0
  fi
  exit "$token_exit_code"
fi

printf 'protocol=https\n'
printf 'host=github.com\n'
printf 'username=x-access-token\n'
printf 'password=%s\n\n' "$token"
