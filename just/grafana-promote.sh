#!/usr/bin/env bash
# Write a Grafana dashboard (ex: an agent's Scratch copy) to a Git Sync
# manifest in this repo.
#
# usage: grafana-promote.sh SCRATCH_UID FILE [UID]
#
# Fetches dashboard SCRATCH_UID from the v2 dashboards k8s API and writes
# FILE as {apiVersion, kind, metadata.name, spec}, w/ the same bytes Git Sync
# writes (+ a trailing newline). Doesn't touch git.
#
# Manifest uid: UID, else FILE's current metadata.name, else SCRATCH_UID w/o
# its `scratch-` prefix.
#
# env: GRAFANA_URL, GRAFANA_USER + GRAFANA_PASSWORD, GRAFANA_TOKEN_FILE. See
# grafana-lib.sh.
set -euo pipefail

# shellcheck source=just/grafana-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/grafana-lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: grafana-promote.sh SCRATCH_UID FILE [UID]

Write Grafana dashboard SCRATCH_UID to the Git Sync manifest FILE.
UID: manifest uid. Default: FILE's metadata.name, else SCRATCH_UID w/o its
`scratch-` prefix.

ex: grafana-promote.sh scratch-nginx nixos/sauna/grafana/nginx.json
USAGE
  exit 2
}

if (($# < 2 || $# > 3)) || [[ $1 == -* || -z $1 || -z $2 ]]; then
  usage
fi
scratch_uid=$1
file=$2
uid=${3:-}

# Pick the manifest uid.
if [[ -z $uid && -f $file ]]; then
  uid=$(jq -r '.metadata.name // empty' "$file") \
    || die "$file: not JSON; pass UID or remove it"
fi
if [[ -z $uid ]]; then
  # Only strip a `scratch-` prefix. Reusing the source uid as is would make
  # Git Sync collide w/ the existing, unmanaged source dashboard.
  if [[ $scratch_uid != scratch-?* ]]; then
    die "no default uid for $scratch_uid (no scratch- prefix); pass UID"
  fi
  uid=${scratch_uid#scratch-}
fi

grafana_init

# Fetch the dashboard as v2. Grafana converts dashboards stored as another
# version on read and flags a failed conversion in `.status.conversion`.
status=$(api GET "$dash_url/$scratch_uid")
case $status in
  200) ;;
  404) die "dashboard $scratch_uid not found" ;;
  *) die "GET dashboard $scratch_uid: HTTP $status: $(resp_error)" ;;
esac
if jq -e '.status.conversion.failed == true' "$tmp/resp" >/dev/null; then
  die "dashboard $scratch_uid: conversion to v2 failed:" \
    "$(jq -r '.status.conversion.error // "unknown error"' "$tmp/resp")"
fi

# Match Git Sync's writer (ParsedResource.ToSaveBytes in
# pkg/registry/apis/provisioning/resources/parser.go): Go's
# json.MarshalIndent sorts map keys, indents by 2, and escapes <, >, & as
# \u003c, \u003e, \u0026. jq emits those raw, and JSON only has them inside
# strings, so a global sed is safe.
# shellcheck disable=SC2016 # jq vars
gjq '.spec | manifest($uid)' --sort-keys --indent 2 --arg uid "$uid" \
  "$tmp/resp" \
  | sed 's/</\\u003c/g; s/>/\\u003e/g; s/&/\\u0026/g' >"$tmp/manifest.json"
jq -e . "$tmp/manifest.json" >/dev/null \
  || die "generated manifest is not valid JSON"

mkdir -p "$(dirname "$file")"
cp "$tmp/manifest.json" "$file"
echo "wrote $file (uid $uid)"
echo "review: git diff -- $file"
