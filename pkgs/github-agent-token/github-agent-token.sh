#!/usr/bin/env bash
set -euo pipefail

# substituted in nix derivation
readonly curl="@curl@"
readonly jq="@jq@"

readonly default_socket="/run/github-agent-authd/socket"
readonly socket_path=${GITHUB_AGENT_AUTHD_SOCKET:-$default_socket}

usage() {
  cat >&2 <<'USAGE'
usage: github-agent-token --repo OWNER/REPO

Fetch a repo-scoped GitHub App installation token from the local
github-agent-authd Unix socket API.

Options:
  --repo OWNER/REPO   Repository to request a token for
  -h, --help          Show this help text
USAGE
}

fail() {
  local code="$1"
  shift
  echo "github-agent-token: $*" >&2
  exit "$code"
}

repo=""
while (($# > 0)); do
  case "$1" in
    --repo)
      (($# >= 2)) || fail 12 "missing value for --repo"
      repo="$2"
      shift 2
      ;;
    --repo=*)
      repo=${1#--repo=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail 12 "unknown argument: $1"
      ;;
  esac
done

[[ -n "$repo" ]] || {
  usage
  fail 12 "--repo is required"
}

if [[ "$repo" != */* ]]; then
  fail 12 "--repo must be OWNER/REPO"
fi

owner=${repo%%/*}
repo_name=${repo#*/}
if [[ -z "$owner" || -z "$repo_name" || "$repo_name" == */* ]]; then
  fail 12 "--repo must be OWNER/REPO"
fi

request_url="http://localhost/repos/${owner}/${repo_name}/token"

if [[ ! -S "$socket_path" ]]; then
  fail 12 "socket not found: $socket_path (is github-agent-authd running?)"
fi

if ! raw_response="$(
  $curl \
    --silent \
    --show-error \
    --connect-timeout 2 \
    --max-time 25 \
    --unix-socket "$socket_path" \
    --write-out $'\n%{http_code}' \
    "$request_url"
)"; then
  fail 12 "request failed (socket=$socket_path repo=$repo)"
fi

http_status=${raw_response##*$'\n'}
response_body=${raw_response%$'\n'*}

if [[ "$http_status" == "200" ]]; then
  if ! token="$($jq -er '.token' <<<"$response_body" \
    2>/dev/null)"; then
    fail 12 "invalid response body"
  fi
  printf '%s\n' "$token"
  exit 0
fi

kind="$($jq -er '.kind // empty' <<<"$response_body" \
  2>/dev/null || true)"
message="$($jq -er '.error // empty' <<<"$response_body" \
  2>/dev/null || true)"
[[ -n "$message" ]] || message="token request failed"

case "$kind" in
  unknown_installation)
    fail 10 "$message"
    ;;
  app_auth_failure)
    fail 11 "$message"
    ;;
  policy_denied)
    fail 13 "$message"
    ;;
  github_api_failure|stale_installation|invalid_request|internal|"")
    if [[ "$http_status" == "403" ]]; then
      fail 13 "$message"
    fi
    fail 12 "$message"
    ;;
  *)
    fail 12 "$message (kind=$kind)"
    ;;
esac
