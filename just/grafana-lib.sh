# shellcheck shell=bash
# Shared helpers for the just/grafana-*.sh dashboard scripts. Source it:
#
#   # shellcheck source=just/grafana-lib.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/grafana-lib.sh"
#
# env:
# - GRAFANA_URL: default https://grafana.phlip9.com
# - GRAFANA_USER + GRAFANA_PASSWORD: basic auth, if both set
# - GRAFANA_TOKEN_FILE: else, service account token file. Default:
#   ~/.config/grafana/mcp-sa-token (the mcp-grafana token)

grafana_url=${GRAFANA_URL:-https://grafana.phlip9.com}
token_file=${GRAFANA_TOKEN_FILE:-$HOME/.config/grafana/mcp-sa-token}
# Dir of these scripts + grafana.jq.
lib_dir=$(dirname "${BASH_SOURCE[0]}")
# Dashboards k8s API (v2 schema).
dash_url="$grafana_url/apis/dashboard.grafana.app/v2/namespaces/default"
dash_url+="/dashboards"

# gjq FILTER [JQ ARGS...]
#
# jq w/ the grafana.jq defs in scope for FILTER, ex: gjq spec_of FILE.
gjq() {
  local filter=$1
  shift
  jq -L "$lib_dir" "include \"grafana\"; $filter" "$@"
}

# die MSG...
die() {
  echo "error: $*" >&2
  exit 1
}

# grafana_init
#
# Make the scratch dir $tmp (removed on exit) and the auth header file.
# Call after arg parsing, so usage errors don't need credentials.
grafana_init() {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  # Auth header file, so secrets never hit argv. Explicit basic auth beats
  # the default token file.
  if [[ -n ${GRAFANA_USER:-} && -n ${GRAFANA_PASSWORD:-} ]]; then
    gjq 'basic_auth_header(env.GRAFANA_USER; env.GRAFANA_PASSWORD)' \
      --null-input --raw-output >"$tmp/auth"
  elif [[ -r $token_file ]]; then
    # shellcheck disable=SC2016 # jq vars
    gjq 'bearer_auth_header($token)' --null-input --raw-output \
      --rawfile token "$token_file" >"$tmp/auth"
  else
    die "no Grafana credentials: no token file at $token_file and" \
      "GRAFANA_USER/GRAFANA_PASSWORD unset"
  fi
}

# api METHOD URL [BODY_FILE]
#
# Send an authenticated request to Grafana, w/ BODY_FILE as a JSON body.
# Prints the HTTP status ("000" if the connection failed). Response body goes
# to $tmp/resp.
api() {
  local args=(
    --silent --show-error
    --request "$1"
    --header @"$tmp/auth"
    --output "$tmp/resp"
    --write-out '%{http_code}'
  )
  if [[ -n ${3:-} ]]; then
    args+=(--header "Content-Type: application/json")
    args+=(--data-binary @"$3")
  fi
  rm -f "$tmp/resp"
  curl "${args[@]}" "$2" || true
}

# resp_error
#
# Print the error from the last response: the `.message` of a k8s Status (or
# Grafana error), else the compact JSON, else the start of the raw body.
resp_error() {
  if ! gjq error_message -j "$tmp/resp" 2>/dev/null; then
    head -c 500 "$tmp/resp" 2>/dev/null
  fi
}

# spec_of FILE
#
# Print the bare v2 dashboard spec of FILE: a Git Sync manifest's `.spec`, or
# FILE itself if it's already a bare spec.
spec_of() {
  gjq spec_of "$1"
}
