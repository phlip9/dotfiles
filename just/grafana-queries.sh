#!/usr/bin/env bash
# Run every panel query of Grafana dashboards, like the browser would.
#
# usage: grafana-queries.sh [--from FROM] [--to TO] FILE|UID...
#
# FILE: a Git Sync manifest or bare v2 spec. UID: a dashboard on the server,
# ex: scratch-nginx. FROM/TO: `now`, `now-<dur>` (ex: now-7d), or epoch ms.
# Default: now-24h .. now.
#
# Sends each panel's queries to Grafana's `/api/ds/query`, which expands
# $__interval, $__rate_interval, $__range, ... server-side. Before that, it
# resolves datasource variables (ex: ${DS_PROMETHEUS}) and substitutes other
# dashboard variables w/ their saved `current` value, formatted like the
# VictoriaMetrics datasource (`All` -> custom allValue, else the saved
# options, else `.*`; unsupported ${var:format}s skip the panel). The step
# mimics a full-width panel: max(queryOptions.interval (default 15s),
# range / (queryOptions.maxDataPoints (default 1000))).
#
# Prints one line per query:
#
#   ok    <element>/<refId>  <n> series, <n> points  <panel title>
#   EMPTY ...                (no non-null points; often legit, ex: idle
#                            queues)
#   FAIL  ...: <error>       (exits 1)
#
# Skips hidden queries. Doesn't run variable or annotation queries.
#
# env: GRAFANA_URL, GRAFANA_USER + GRAFANA_PASSWORD, GRAFANA_TOKEN_FILE. See
# grafana-lib.sh.
set -euo pipefail

# shellcheck source=just/grafana-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/grafana-lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: grafana-queries.sh [--from FROM] [--to TO] FILE|UID...

Run every panel query of each dashboard (manifest/spec FILE or server UID)
through Grafana's /api/ds/query. FROM/TO: now, now-<dur>, or epoch ms.
Default: now-24h .. now. Exits 1 if any query fails.

ex: grafana-queries.sh --from now-7d scratch-nginx
USAGE
  exit 2
}

from=now-24h
to=now
targets=()
while (($# > 0)); do
  case $1 in
    --from)
      (($# > 1)) || usage
      from=$2
      shift 2
      ;;
    --to)
      (($# > 1)) || usage
      to=$2
      shift 2
      ;;
    -*) usage ;;
    *)
      targets+=("$1")
      shift
      ;;
  esac
done
((${#targets[@]} > 0)) || usage

grafana_init

failed=0
now_ms=$(($(date +%s) * 1000))
for target in "${targets[@]}"; do
  # Dashboard spec from a file, else from the server.
  if [[ -f $target ]]; then
    spec_of "$target" >"$tmp/spec.json" 2>/dev/null \
      || die "$target: not JSON"
  else
    status=$(api GET "$dash_url/$target")
    [[ $status == 200 ]] \
      || die "GET dashboard $target: HTTP $status: $(resp_error)"
    jq .spec "$tmp/resp" >"$tmp/spec.json"
  fi

  echo "# $target ($from .. $to)"
  # One record per panel: element, title, skip reason, request body
  # (compact JSON), each NUL-terminated, so the loop spawns no jq per field.
  # shellcheck disable=SC2016 # jq vars
  gjq 'panel_requests($now; $from; $to)
    | .element, .title, .skip // "", (.body | tojson)' --raw-output0 \
    --argjson now "$now_ms" --arg from "$from" --arg to "$to" \
    "$tmp/spec.json" >"$tmp/requests" \
    || die "$target: can't build queries"

  while IFS= read -r -d '' element && IFS= read -r -d '' title \
    && IFS= read -r -d '' skip && IFS= read -r -d '' body; do
    if [[ -n $skip ]]; then
      printf '%-5s %s  (%s)  %s\n' SKIP "$element" "$skip" "$title"
      continue
    fi
    printf '%s' "$body" >"$tmp/body.json"
    status=$(api POST "$grafana_url/api/ds/query" "$tmp/body.json")
    # 207 = some queries failed; their errors are in .results.
    if ! results=$(gjq 'if .results == null then error("no results")
        else query_results end' -r "$tmp/resp" 2>/dev/null); then
      printf '%-5s %s: HTTP %s: %s  %s\n' FAIL "$element" "$status" \
        "$(resp_error)" "$title"
      failed=1
      continue
    fi
    while IFS=$'\t' read -r verdict ref detail; do
      [[ -n $verdict ]] || continue
      [[ $verdict == FAIL ]] && failed=1
      printf '%-5s %s/%s  %s  %s\n' "$verdict" "$element" "$ref" "$detail" \
        "$title"
    done <<<"$results"
  done <"$tmp/requests"
done
exit "$failed"
