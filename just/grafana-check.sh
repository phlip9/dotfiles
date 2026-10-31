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
# env: GRAFANA_URL, GRAFANA_USER + GRAFANA_PASSWORD, GRAFANA_TOKEN_FILE. See
# grafana-lib.sh.
set -euo pipefail

# shellcheck source=just/grafana-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/grafana-lib.sh"

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

grafana_init

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
