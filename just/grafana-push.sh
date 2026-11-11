#!/usr/bin/env bash
# Upload a dashboard file to an unmanaged copy in the Grafana `Scratch` folder.
#
# usage: grafana-push.sh [--force] FILE [SCRATCH_UID]
#
# FILE: a Git Sync manifest ({apiVersion, kind, metadata, spec}) or a bare v2
# dashboard spec. SCRATCH_UID: default `scratch-<FILE stem>`, ex:
# nixos/sauna/grafana/nginx.json -> scratch-nginx.
#
# Creates the `Scratch` folder (uid `scratch`) and the copy if missing, else
# replaces the copy's whole spec. Unlike mcp-grafana's `update_dashboard`,
# the spec never passes through the agent's context, so this works for any
# dashboard size.
#
# Refuses to replace a copy saved by anyone else since our last push of /
# pull into FILE (ex: the user's UI edits, `update_dashboard` patches,
# `grafana-resave`), or an existing copy never synced w/ FILE (ex: another
# file's or worktree's): pull it into FILE first w/ `grafana-promote.sh`,
# or pass --force to discard it. Tracks the copy's generation per FILE in
# grafana-lib.sh's $sync_dir.
#
# The copy's tags get a `scratch-` prefix (grafana-promote.sh strips it), so
# tag-based dashboard lists, like the "Dashboards" link dropdown, never show
# copies.
#
# Refuses uids w/o a `scratch-` prefix and dashboards outside `Scratch`, so it
# can't save a Git Sync managed dashboard (= a commit on `master`).
#
# env: GRAFANA_URL, GRAFANA_USER + GRAFANA_PASSWORD, GRAFANA_TOKEN_FILE. See
# grafana-lib.sh.
set -euo pipefail

# shellcheck source=just/grafana-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/grafana-lib.sh"
folder_uid=scratch

usage() {
  cat >&2 <<'USAGE'
usage: grafana-push.sh [--force] FILE [SCRATCH_UID]

Upload FILE (Git Sync manifest or bare v2 spec) to the Scratch folder as
SCRATCH_UID (default: scratch-<FILE stem>). Replaces the copy's whole spec.
Refuses if the copy changed since our last push of / promote into FILE (or
we never synced it w/ FILE), unless --force.

ex: grafana-push.sh nixos/sauna/grafana/nginx.json
USAGE
  exit 2
}

force=false
if [[ ${1:-} == --force ]]; then
  force=true
  shift
fi
if (($# < 1 || $# > 2)) || [[ $1 == -* || -z $1 ]]; then
  usage
fi
file=$1
stem=$(basename "$file" .json)
uid=${2:-scratch-$stem}

if [[ $uid != scratch-?* ]]; then
  die "uid $uid has no scratch- prefix"
fi
[[ -r $file ]] || die "$file: not readable"

grafana_init

spec_of "$file" >"$tmp/spec.json" 2>/dev/null || die "$file: not JSON"
gjq is_v2_spec -e "$tmp/spec.json" >/dev/null \
  || die "$file: not a v2 dashboard spec (no .elements + .layout)"

# Create the Scratch folder on first use. The legacy folders API grants the
# default role permissions, so Editor service accounts can use it. A missing
# folder is a 403 (not 404) for Editors: access control can't resolve it.
get_status=$(api GET "$grafana_url/api/folders/$folder_uid")
case $get_status in
  200) ;;
  403 | 404)
    jq --null-input --arg uid "$folder_uid" '{uid: $uid, title: "Scratch"}' \
      >"$tmp/folder.json"
    status=$(api POST "$grafana_url/api/folders" "$tmp/folder.json")
    [[ $status == 200 ]] \
      || die "create folder $folder_uid (GET was HTTP $get_status):" \
        "HTTP $status: $(resp_error)"
    ;;
  *) die "GET folder $folder_uid: HTTP $get_status: $(resp_error)" ;;
esac

# Update the copy in place (w/ its resourceVersion) if it exists, else create
# it. Never touch a dashboard outside Scratch or managed by Git Sync.
status=$(api GET "$dash_url/$uid")
case $status in
  200)
    # shellcheck disable=SC2016 # jq vars
    gjq 'unmanaged_in($folder)' -e --arg folder "$folder_uid" "$tmp/resp" \
      >/dev/null \
      || die "dashboard $uid exists outside the $folder_uid folder" \
        "or is managed by Git Sync; refusing to overwrite"
    # Someone else saved the copy since our last push/pull? W/o a record,
    # we can't tell: refuse too.
    synced=$(synced_generation "$uid" "$file")
    current=$(jq -r '.metadata.generation' "$tmp/resp")
    if [[ $force == false && -z $synced ]]; then
      die "$uid exists, but we never pushed/promoted it w/ $file (ex:" \
        "another file's or worktree's copy), so it may have edits $file" \
        "lacks. Pull it w/ grafana-promote $uid $file and edit that, or" \
        "rerun w/ --force to replace it."
    fi
    if [[ $force == false && $synced != "$current" ]]; then
      saved_by=$(gjq saved_by -r "$tmp/resp")
      die "$uid changed since our last push/promote w/ $file (generation" \
        "$synced -> $current, last saved by $saved_by; ex: UI edits)." \
        "Pull them w/ grafana-promote $uid $file and edit that, or rerun" \
        "w/ --force to discard them."
    fi
    method=PUT
    url="$dash_url/$uid"
    rv=$(jq -r '.metadata.resourceVersion' "$tmp/resp")
    ;;
  404)
    method=POST
    url=$dash_url
    rv=
    ;;
  *) die "GET dashboard $uid: HTTP $status: $(resp_error)" ;;
esac

# shellcheck disable=SC2016 # jq vars
gjq 'scratch_tags | manifest($uid)
  | .metadata.annotations = {"grafana.app/folder": $folder}
  | if $rv == "" then . else .metadata.resourceVersion = $rv end' \
  --arg uid "$uid" --arg folder "$folder_uid" --arg rv "$rv" \
  "$tmp/spec.json" >"$tmp/body.json"

status=$(api "$method" "$url" "$tmp/body.json")
case $status in
  200 | 201) ;;
  *) die "$method dashboard $uid: HTTP $status: $(resp_error)" ;;
esac
record_sync "$uid" "$file"
echo "pushed $file -> $grafana_url/d/$uid"
