#!/usr/bin/env bash
# Validate Grafana Git Sync dashboard manifests server-side, w/o saving.
#
# usage: grafana-check.sh [FILE.json...]
#
# Default: every nixos/sauna/grafana/*.json. For each v2 manifest, sends a
# dry-run PUT (`?dryRun=All`) to the dashboards k8s API, which runs the same
# decode and admission as a real save, then prints `ok` or the server's
# error. Exits non-zero if any fail.
#
# Catches (Grafana 13.2.4): wrong JSON types, unknown fields, empty title,
# bad tags/refresh. Misses: unknown layout/variable kinds, bad enum values,
# layout refs to missing elements.
#
# env:
# - GRAFANA_URL: default https://grafana.phlip9.com
# - GRAFANA_USER + GRAFANA_PASSWORD: basic auth, if both set
# - GRAFANA_TOKEN_FILE: else, service account token file. Default:
#   ~/.config/grafana/mcp-sa-token (the mcp-grafana token)
#
# A dry run can't write or commit (Grafana 13.2.4, k8s.io/apiserver v0.36.2):
# - The generic k8s registry wraps storage in `DryRunnableStorage`
#   (k8s.io/apiserver pkg/registry/generic/registry/{store,dryrun}.go). On a
#   dry run, Create/GuaranteedUpdate only Get the current object, run the
#   strategy + admission, and echo the result. They never call the wrapped
#   storage's Create/GuaranteedUpdate.
# - The wrapped storage is unified storage
#   (pkg/storage/unified/apistore/store.go). Its Create/GuaranteedUpdate hold
#   the Git Sync re-routing of repo-managed writes
#   (apistore/managed.go: handleManagedResourceRouting), so no commit.
# - pkg/storage/legacysql/dualwrite/dualwriter.go sends dry runs straight to
#   unified storage. pkg/registry/apis/dashboard/register.go skips folder and
#   quota side effects on IsDryRun().
# - Caveat: dashboardStorageWrapper.Update
#   (pkg/registry/apis/dashboard/dashboard_storage.go) still broadcasts a
#   Grafana Live "saved" event, so open browser tabs of the dashboard reload.
set -euo pipefail

grafana_url=${GRAFANA_URL:-https://grafana.phlip9.com}
token_file=${GRAFANA_TOKEN_FILE:-$HOME/.config/grafana/mcp-sa-token}
dash_url="$grafana_url/apis/dashboard.grafana.app/v2/namespaces/default"
dash_url+="/dashboards"
# Git Sync also writes v2 dashboards w/ strict field validation, which
# rejects unknown fields.
# See: pkg/registry/apis/provisioning/resources/parser.go
query="dryRun=All&fieldValidation=Strict"

usage() {
  cat >&2 <<'USAGE'
usage: grafana-check.sh [FILE.json...]

Dry-run save Grafana dashboard manifests (default: nixos/sauna/grafana/*.json).
USAGE
  exit 2
}

# No flags; `-h`, `--help`, or a typo gets the usage text.
for arg in "$@"; do
  if [[ $arg == -* ]]; then
    usage
  fi
done

files=("$@")
if ((${#files[@]} == 0)); then
  files=(nixos/sauna/grafana/*.json)
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Auth header file, so secrets never hit argv. Explicit basic auth beats
# the default token file.
if [[ -n ${GRAFANA_USER:-} && -n ${GRAFANA_PASSWORD:-} ]]; then
  jq --null-input --raw-output \
    '"Authorization: Basic \("\(env.GRAFANA_USER):\(env.GRAFANA_PASSWORD)"
      | @base64)"' >"$tmp/auth"
elif [[ -r $token_file ]]; then
  jq --null-input --raw-output --rawfile token "$token_file" \
    '"Authorization: Bearer \($token | trim)"' >"$tmp/auth"
else
  echo "error: no Grafana credentials: no token file at $token_file and" \
    "GRAFANA_USER/GRAFANA_PASSWORD unset" >&2
  exit 1
fi

# api METHOD URL [BODY_FILE]
#
# Send an authenticated request to Grafana. Prints the HTTP status ("000" if
# the connection failed). Response body goes to $tmp/resp.
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
  if ! jq -j '
    if (.message? // "") != "" then .message else tojson end
  ' "$tmp/resp" 2>/dev/null; then
    head -c 500 "$tmp/resp" 2>/dev/null
  fi
}

failed=0
for file in "${files[@]}"; do
  # Local checks: a JSON object w/ a dashboard uid in `metadata.name`.
  if ! name=$(jq -er '.metadata.name | strings' "$file" 2>/dev/null); then
    echo "FAIL $file: missing, not JSON, or no metadata.name"
    failed=1
    continue
  fi
  jq '.metadata.namespace = "default"' "$file" >"$tmp/body.json"

  # Dry-run replace the dashboard. Grafana allows create-on-update, so a new
  # name dry-runs a create; POST covers a 404 anyway.
  status=$(api PUT "$dash_url/$name?$query" "$tmp/body.json")
  if [[ $status == 404 ]]; then
    status=$(api POST "$dash_url?$query" "$tmp/body.json")
  fi

  if [[ $status == 200 || $status == 201 ]]; then
    echo "ok   $file"
  else
    echo "FAIL $file: HTTP $status: $(resp_error)"
    failed=1
  fi
done

exit "$failed"
