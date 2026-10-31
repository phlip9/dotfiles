#!/usr/bin/env bash
# Print the layout tree of Grafana v2 dashboards: rows/tabs -> panels.
#
# usage: grafana-outline.sh [--queries] FILE|UID...
#
# FILE: a Git Sync manifest or bare v2 spec. UID: a dashboard on the server,
# ex: scratch-nginx (needs credentials; files don't).
#
# One line per panel, in reading order (y, then x):
#
#   <id> <element key> <viz> <x>,<y> <w>x<h> q=<queries> "<title>"
#
# --queries: also print each query's refId + expr (whitespace collapsed).
#
# Gives agents a map of a dashboard w/o reading the whole spec: ex,
# node-exporter-full shrinks from 750 KiB to ~12 KB. Use the element keys to
# pull details w/ jq, ex: jq '.spec.elements["panel-15"]' FILE.
#
# env: GRAFANA_URL, GRAFANA_USER + GRAFANA_PASSWORD, GRAFANA_TOKEN_FILE. See
# grafana-lib.sh.
set -euo pipefail

# shellcheck source=just/grafana-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/grafana-lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: grafana-outline.sh [--queries] FILE|UID...

Print each dashboard's (manifest/spec FILE or server UID) rows/tabs and
panels: id, element key, viz, position, size, query count, title.
--queries: also print each panel's query exprs.

ex: grafana-outline.sh nixos/sauna/grafana/node-exporter-full.json
USAGE
  exit 2
}

queries=false
targets=()
while (($# > 0)); do
  case $1 in
    --queries)
      queries=true
      shift
      ;;
    -*) usage ;;
    *)
      targets+=("$1")
      shift
      ;;
  esac
done
((${#targets[@]} > 0)) || usage

tmp=
for target in "${targets[@]}"; do
  # Dashboard spec from a file, else from the server.
  if [[ -f $target ]]; then
    spec=$(spec_of "$target" 2>/dev/null) || die "$target: not JSON"
  else
    [[ -n $tmp ]] || grafana_init
    status=$(api GET "$dash_url/$target")
    [[ $status == 200 ]] \
      || die "GET dashboard $target: HTTP $status: $(resp_error)"
    spec=$(jq .spec "$tmp/resp")
  fi
  gjq is_v2_spec -e <<<"$spec" >/dev/null \
    || die "$target: not a v2 dashboard spec (no .elements + .layout)"

  echo "# $target"
  # shellcheck disable=SC2016 # jq vars
  gjq 'outline($queries)' -r --argjson queries "$queries" <<<"$spec"
done
