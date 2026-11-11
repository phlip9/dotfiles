# Shared jq defs for the just/grafana-*.sh dashboard scripts. Use via
# grafana-lib.sh's "gjq FILTER [JQ ARGS...]", which runs jq w/ this module
# included, ex: gjq spec_of FILE.
#
# Defs only see their input + params, not the caller's --arg globals.

# --- manifests + specs --- #

# Bare v2 dashboard spec of a Git Sync manifest (its `.spec`), or the input
# itself if it's already a bare spec.
def spec_of: if .apiVersion? and .spec? then .spec else . end;

# Whether the input looks like a v2 dashboard spec.
def is_v2_spec: (.elements? | type == "object") and .layout? != null;

# Git Sync manifest of the input spec w/ dashboard uid `$uid`.
def manifest($uid): {
  apiVersion: "dashboard.grafana.app/v2",
  kind: "Dashboard",
  metadata: {name: $uid},
  spec: .
};

# The input spec w/ a `scratch-` prefix on each tag, for a Scratch copy. Tag
# searches (ex: a "dashboards" link w/ tags, the browse page tag filter) then
# never list the copy next to the real dashboard. Always adds one prefix, so
# unscratch_tags is its exact inverse, even for tags already starting w/
# `scratch-`.
def scratch_tags: if .tags then .tags |= map("scratch-" + .) else . end;

# The input spec w/o scratch_tags' prefix: strips exactly one `scratch-`.
def unscratch_tags: if .tags then .tags |= map(ltrimstr("scratch-")) else . end;

# Queries ([PanelQuery.spec]) of the input panel spec.
def panel_queries: [.data.spec.queries[]?.spec];

# --- API objects --- #

# The input dashboard resource's metadata annotations.
def annotations: .metadata.annotations // {};

# Whether the input dashboard resource is in folder `$folder` and not
# managed by Git Sync (saving it won't commit to `master`).
def unmanaged_in($folder):
  annotations
  | .["grafana.app/folder"] == $folder and .["grafana.app/managedBy"] == null;

# "<who> at <when>" the input dashboard resource was last saved.
def saved_by:
  annotations
  | "\(.["grafana.app/updatedBy"] // "?")"
    + " at \(.["grafana.app/updatedTimestamp"] // "?")";

# Error text of an API response: the `.message` of a k8s Status (or Grafana
# error), else the compact JSON.
def error_message:
  if (.message? // "") != "" then .message else tojson end;

# --- auth --- #

# `Authorization` header line for basic auth `$user` + `$password`.
def basic_auth_header($user; $password):
  "Authorization: Basic \("\($user):\($password)" | @base64)";

# `Authorization` header line for (service account) token `$token`.
def bearer_auth_header($token): "Authorization: Bearer \($token | trim)";

# --- time --- #

# Grafana duration (ex: 15s, 1h) -> ms.
def dur_ms:
  (capture("^(?<n>[0-9.]+)(?<u>ms|s|m|h|d|w|y)$")
    // error("invalid duration: \(.)"))
  | (.n | tonumber) * {
      ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000,
      w: 604800000, y: 31536000000
    }[.u];

# `now`, `now-<dur>`, or epoch ms -> epoch ms, given `$now` in epoch ms.
def time_ms($now):
  if . == "now" then $now
  elif startswith("now-") then $now - (.[4:] | dur_ms)
  elif test("^[0-9]+$") then tonumber
  else error("unsupported time: \(.)") end;

# --- grafana-queries --- #

# Saved variables of the input spec: {name: {values, options, multi, all,
# all_value}}. `values`: the selected values as strings; `options`: the
# saved option values, w/o All; `all`: "All" is selected.
def saved_variables:
  [.variables[]?.spec | select(.name)
    | ([.current.value // ""] | flatten | map(tostring)) as $values
    | {key: .name, value: {
        values: $values,
        options: ([.options[]?.value | tostring] - ["$__all"]),
        multi: ((.multi // false) or (.includeAll // false)),
        all: any($values[]; . == "$__all"),
        all_value: .allValue}}]
  | from_entries;

# Escape the input for a PromQL "..." string, like the VictoriaMetrics
# datasource's prometheusRegularEscape.
def promql_string_escape: gsub("\\\\"; "\\\\") | gsub("'"; "\\\\'");

# Escape regex specials in the input for a regex matcher inside a PromQL
# "..." string, like the datasource's prometheusSpecialRegexEscape.
def promql_regex_escape:
  gsub("\\\\"; "\\\\\\\\") | gsub("(?<c>[$^*{}\\[\\]'+?.()|])"; "\\\\\(.c)");

# Regex-escape the input, like Grafana's `regex` format.
def regex_escape: gsub("(?<c>[\\\\^$*+?.()|\\[\\]{}/])"; "\\\(.c)");

# Values `.` as one regex alternative: `a` or `(a|b)`.
def regex_alternation: if length == 1 then .[0] else "(\(join("|")))" end;

# Expansion of saved variable `$var` (see saved_variables) w/ format `$fmt`
# (null: the default), like the VictoriaMetrics datasource. "All": the
# custom allValue as is, else every saved option; w/o saved options (ex:
# query variables), `.*`.
def format_variable($var; $fmt):
  if [null, "regex", "pipe", "raw", "csv"] | index([$fmt]) | not then
    error("unsupported variable format :\($fmt)")
  elif $var.all and ($var.all_value // "") != "" then $var.all_value
  elif $var.all and ($var.options | length) == 0 then ".*"
  else
    (if $var.all then $var.options else $var.values end) as $values
    | if $fmt == null then
        if $var.multi then $values | map(promql_regex_escape)
          | regex_alternation
        else $values | map(promql_string_escape) | join(",") end
      elif $fmt == "regex" then $values | map(regex_escape)
        | regex_alternation
      elif $fmt == "pipe" then $values | join("|")
      else $values | join(",") end
  end;

# Substitute saved variables `$vars` (see saved_variables) for ${name},
# ${name:fmt}, and $name in the input string.
def interpolate($vars):
  reduce ($vars | to_entries[]) as $var (.;
    gsub("\\$\\{\($var.key)(:(?<fmt>[^}]*))?\\}";
      format_variable($var.value; .fmt))
    | gsub("\\$\($var.key)(?![A-Za-z0-9_])";
      format_variable($var.value; null)));

# One /api/ds/query request per panel of the input spec, like the browser
# would send for time range `$from`..`$to` (see time_ms) at `$now` (epoch
# ms): {element, title, body} or {element, title, skip}. The step mimics a
# full-width panel: max(queryOptions.interval (default 15s),
# range / queryOptions.maxDataPoints (default 1000)).
def panel_requests($now; $from; $to):
  saved_variables as $vars
  | ($from | time_ms($now)) as $from_ms
  | ($to | time_ms($now)) as $to_ms
  | .elements | to_entries[]
  | select(.value.kind == "Panel")
  | .key as $element
  | .value.spec as $panel
  | ($panel.data.spec.queryOptions // {}) as $opts
  | ([($opts.interval // "15s" | dur_ms),
      (($to_ms - $from_ms) / ($opts.maxDataPoints // 1000))]
      | max | . / 1000 | ceil * 1000) as $interval_ms
  # Unsupported variable formats -> skip, not a different query.
  | (try [$panel | panel_queries[] | select(.hidden != true)
      # Resolve datasource variables (ex: ${DS_PROMETHEUS}) to uids.
      | (.query.datasource.name // .query.datasource.uid // null) as $ds
      | ($ds | if type == "string" and startswith("$") then
          ($vars[ltrimstr("${") | ltrimstr("$") | rtrimstr("}")]
            .values[0]?)
        else . end) as $ds_uid
      | (.query.spec // {}
          | walk(if type == "string" then interpolate($vars) else . end))
        + {refId: .refId, datasource: {uid: $ds_uid},
           intervalMs: $interval_ms,
           maxDataPoints: ($opts.maxDataPoints // 1000)}]
     catch {error: .}) as $queries
  | {element: $element, title: ($panel.title // "")}
    + if ($queries | type) == "object" then {skip: $queries.error}
      elif ($queries | length) == 0 then {skip: "no queries"}
      elif any($queries[]; .datasource.uid == null) then
        {skip: "unresolved datasource"}
      else {body: {from: ($from_ms | tostring), to: ($to_ms | tostring),
                   queries: $queries}} end;

# Summary of an /api/ds/query response, one TSV line per query:
# verdict (ok / EMPTY / FAIL), refId, detail. Points: non-null values (the
# fields after each frame's time field).
def query_results:
  .results // {} | to_entries[]
  | .key as $ref
  | .value as $res
  | if ($res.error // "") != "" then ["FAIL", $ref, $res.error]
    else
      ([$res.frames[]?
        | [.data.values[1:][]?[]? | select(. != null)] | length]) as $lens
      | ([$lens[] | select(. > 0)] | length) as $series
      | ($lens | add // 0) as $points
      | [(if $points > 0 then "ok" else "EMPTY" end), $ref,
         "\($series) series, \($points) points"]
    end
  | @tsv;

# --- grafana-outline --- #

def _pad($n): if $n > 0 then " " * $n else "" end;
def _rpad($n): tostring | . + _pad($n - length);
def _lpad($n): tostring | _pad($n - length) + .;
def _indent($depth): _pad(2 * $depth);

# Outline lines of a placed element (input: a layout item's spec): a summary
# line, then (if `$queries`) its query exprs.
def _outline_item($els; $depth; $queries):
  .element.name as $key
  | ($els[$key] // {kind: "missing", spec: {}}) as $el
  | ($el.spec | panel_queries) as $qs
  | (if .width then "\(.x // 0),\(.y // 0) \(.width)x\(.height)"
     else "auto" end) as $geo
  | _indent($depth) + ($el.spec.id // "-" | _lpad(4)) + " "
    + ($key | _rpad(24)) + " "
    + ($el.spec.vizConfig.group // ($el.kind | ascii_downcase) | _rpad(14))
    + " " + ($geo | _rpad(11)) + " q=\($qs | length) "
    + ($el.spec.title // "" | @json),
    if $queries then
      $qs[]
      | _indent($depth + 3) + "\(.refId):"
        + (if .hidden then " (hidden)" else "" end) + " "
        + (.query.spec.expr // (.query.spec | tojson) | gsub("\\s+"; " "))
    else empty end;

# Outline lines of a layout (input) and its nested layouts.
def _outline_layout($els; $depth; $queries):
  .kind as $kind
  | .spec as $spec
  | if $kind == "RowsLayout" then
      $spec.rows[].spec
      | _indent($depth) + "row " + (.title // "" | @json)
        + (if .collapse then " (collapsed)" else "" end),
        (.layout | _outline_layout($els; $depth + 1; $queries))
    elif $kind == "TabsLayout" then
      $spec.tabs[].spec
      | _indent($depth) + "tab " + (.title // "" | @json),
        (.layout | _outline_layout($els; $depth + 1; $queries))
    elif $kind == "GridLayout" then
      # Reading order.
      $spec.items | sort_by(.spec.y // 0, .spec.x // 0) | .[]
      | .spec | _outline_item($els; $depth; $queries)
    elif $kind == "AutoGridLayout" then
      $spec.items[].spec | _outline_item($els; $depth; $queries)
    else
      _indent($depth) + "(\($kind))"
    end;

# All element names referenced by the input layout.
def element_refs:
  [.. | objects | select(.kind? == "ElementReference") | .name];

# Outline of the input v2 spec, one line per row/tab/panel:
#   <id> <element key> <viz> <x>,<y> <w>x<h> q=<queries> "<title>"
# then unplaced elements. `$queries`: also print query exprs.
def outline($queries):
  .elements as $els
  | (.layout | element_refs) as $placed
  | "\(.title // "" | @json): \($els | length) elements, vars: "
    + ([.variables[]?.spec.name] | join(", ")),
    (.layout | _outline_layout($els; 0; $queries)),
    (($els | keys) - $placed | select(length > 0)
     | "unplaced: " + join(", "));
