---
name: grafana-dashboard
description: Use before any Grafana work on grafana.phlip9.com, incl. every mcp-grafana tool call - querying metrics, reading dashboards, and designing, building, updating, or promoting dashboards (nixos/sauna/grafana/*.json, Git Sync from master, Scratch-folder previews)
---

# grafana

`grafana.phlip9.com`: Grafana 13 OSS, VictoriaMetrics (metrics) + Pyroscope
(profiles, see [Profiles](#profiles)) datasources, dashboards Git Sync'd from
`master`. Basics apply to any Grafana work; the rest is for building and
changing dashboards.

## Basics

- **Never write outside Scratch.** Every server-side save of a synced dashboard
  (UI, API, mcp `update_dashboard`) is a commit on `master`. Only write
  unmanaged `scratch-*` copies in the folder uid `scratch`. The `just
  grafana-*` tools enforce this; for mcp writes, you do.
- Metrics datasource: `{"type": "victoriametrics-metrics-datasource", "uid":
  "victoriametrics"}` (PromQL + MetricsQL). `victoriametrics` is the
  `datasourceUid` for mcp `query_prometheus` / `list_prometheus_*`.
- Schema: v2 only. Panels in `spec.elements.<key>` (kind `Panel`), placed by
  `spec.layout` (RowsLayout, GridLayout, TabsLayout, AutoGridLayout items ->
  `ElementReference`), variables in `spec.variables[]`. A panel query:
  `{"kind": "DataQuery", "group": "victoriametrics-metrics-datasource",
  "version": "v0", "datasource": {"name": "${DS_PROMETHEUS}"}, "spec": {"expr":
  "..."}}` (the dashboard's datasource variable).
- Manifests: one per dashboard, `nixos/sauna/grafana/<name>.json` =
  `{"apiVersion": "dashboard.grafana.app/v2", "kind": "Dashboard", "metadata":
  {"name": <uid>}, "spec": ...}` in Git Sync's Go-style JSON. A push to
  `master` updates the live dashboard within seconds.
- Reading: map first w/ `just grafana-outline [--queries] FILE|UID` (or mcp
  `get_dashboard_summary`), then `jq` on repo files, or mcp
  `get_dashboard_property` / `get_dashboard_panel_queries` on live ones. Avoid
  `get_dashboard_by_uid` on big dashboards (node-exporter-full is 750 KiB).
- Links for the user: mcp `generate_deeplink` or
  `https://grafana.phlip9.com/d/<uid>`.

## Workflow

New or reworked dashboard:

1. discover: metrics, labels, semantics, history
2. design: questions -> rows -> panels; confirm scope w/ user if fuzzy
3. build: generator script -> manifest -> `just grafana-push`
4. verify: `just grafana-queries`, `just grafana-screenshot`, look at it
5. iterate w/ the user on the Scratch copy
6. `just grafana-resave` -> `just grafana-promote` -> commit

Changing an existing dashboard (one query, a new panel, a new row): see
[Update an existing dashboard](#update-an-existing-dashboard).

## Tools

| what | how |
|---|---|
| map a dashboard | `just grafana-outline [--queries] FILE\|UID...` (rows -> id, key, viz, geometry, title, exprs) |
| explore metrics | mcp-grafana `list_prometheus_metric_names`, `query_prometheus`, `list_prometheus_metric_metadata` (TYPE/HELP) |
| seed/replace Scratch copy | `just grafana-push [--force] FILE [scratch-uid]` (default `scratch-<stem>`; any size; creates folder; refuses if someone saved the copy since FILE's last push/promote, or FILE was never synced w/ it) |
| edit a manifest file | `dash.py`: `Dashboard.load(FILE)` ... `.write(FILE)` (diff = only your edits) |
| patch Scratch copy | mcp `update_dashboard {uid, operations}` (keeps the user's UI edits) |
| run all panel queries | `just grafana-queries [--from now-7d] FILE\|UID...` (ok / EMPTY / FAIL) |
| look at it | `just grafana-screenshot UID [--from now-7d] [--expand] [--panel ID] -o tmp/x.png`, then Read the PNG |
| fill in UI defaults | `just grafana-resave scratch-<x>` (headless UI Save of the copy) |
| schema dry-run | `just grafana-check FILE` |
| keep result | `just grafana-promote scratch-<x> nixos/sauna/grafana/<x>.json` |

Scratch work lives in `tmp/<name>/` (gitignored). Auth for all `just
grafana-*`: `~/.config/grafana/mcp-sa-token` (Editor service account).

## 1. Discover

- List the job's metrics: `count by (__name__) ({job="<job>"})`, instant.
  Scrape config: `nixos/mods/o11y/default.nix` (`scrape_configs`, 1m interval).
- Check TYPE/HELP w/ `list_prometheus_metric_metadata`. Don't trust names:
  read the exporter source when semantics matter. Pinned sources:
  `nix eval --raw -f . sources.<name>.outPath`, then grep for the metric.
- Watch for:
  - gauges that act like counters but shrink (DB row counts w/ retention
    cleanup, ex: nixbot): use `pos_delta` (below), never `increase()`.
  - metrics w/o samples when idle (ex: `*_oldest_age_seconds` only while
    work is pending): `noValue` text, or `or vector(0)` for stats.
  - transient status labels (`pending`, `running`, `building`): filter
    them out of "results per interval" charts.
  - in-process metrics that don't cover out-of-process work (ex: a GC
    oneshot unit): use node-exporter systemd metrics
    (`node_systemd_unit_state`, `node_systemd_timer_last_trigger_seconds`).
- Check history depth: `count_over_time(up{job="<job>"}[1d])` over 14d.
- Run candidate queries w/ `query_prometheus` and sanity-check numbers
  before building panels on them.

## 2. Design

Answer the operator's questions top-down: "is it up / healthy?" (stat
row), "what happened?" (events over time), "why?" (latency, queues,
errors), "is the host OK?" (runtime row, collapsed).

Conventions (see `nixos/sauna/grafana/nix-ci.json` as the reference):

- `RowsLayout`; each row a `GridLayout`, 24 columns. Overview row first:
  stat tiles w=4 h=4, 6 per line. Detail rows: 2-3 panels per line, h=7-8.
  Collapse rarely used rows (runtime/host).
- Every panel gets a 1-sentence `description` (units, caveats, what an
  anomaly looks like).
- Stats: background sparkline on every tile. `up` tiles: value mapping
  UP/DOWN + `colorMode: background`.
- Range totals in stats: per-interval counts + `calc: "sum"`; ratios and
  means as running ratios (`running_sum(a) / running_sum(b)`) w/
  `lastNotNull`. Don't use `[$__range]` instant queries: no sparkline.
- Event counts: stacked bars, >= 1h buckets (`queryOptions: {interval:
  "1h", maxDataPoints: 200}`), legend table w/ `sum`.
- Status colors reserved: succeeded green, failed red, cancelled/skipped
  gray. Hide a dominating series by default (`custom.hideFrom.viz`).
- One y-axis per panel; different units -> separate panels.
- Units: `s`, `bytes`, `Bps`, `reqps`, `percentunit`, `short`.
- Datasource via the `DS_PROMETHEUS` DatasourceVariable, like the others.
- Default time range matches event density (CI: 7d; HTTP: 24h).
- Values copied from config (alert thresholds, oomd limits, unit/job
  names, probe URLs, metric label shapes): dashboard JSON can't hold
  comments, so add `Keep in sync: nixos/sauna/grafana/<x>.json "<panel>"
  (<what>)` at the source. When changing such a source, `rg 'Keep in sync'`
  near it and update the dashboard too.

## 3. Build

Write `tmp/<name>/gen.py` using the builder library:

```python
import sys
sys.path.insert(0, ".agents/skills/grafana-dashboard/scripts")
from dash import BARS, STATUS_COLORS, Dashboard, color, hidden, pos_delta, thresholds
```

See the `scripts/dash.py` docstrings: `Dashboard.stat`, `.timeseries`,
`.panel` (any other viz, raw options), `.row`, `.write(path, uid=...)`.
It validates element refs + row widths and writes Grafana's own JSON
formatting. Then:

```bash
$ python3 tmp/<name>/gen.py           # writes tmp/<name>/<name>.json
$ just grafana-check tmp/<name>/<name>.json
$ just grafana-push tmp/<name>/<name>.json
```

Never hand-write a big spec into a tool call, and never pass large JSON
via curl `-d "$(...)"` (argv limit): use files + `--data-binary @file`.

MetricsQL patterns (VictoriaMetrics):

```promql
# events from a shrinking gauge, per panel interval (dash.pos_delta)
sum by (status) (sum_over_time(clamp_min(delta(x{status=~"ok|failed"}[1m]), 0)[$__interval:1m]))
# running success rate over the dashboard range (stat sparkline + value)
running_sum(sum(OK_EVENTS)) / running_sum(sum(ALL_EVENTS))
# real counter, per interval / per second
sum(increase(x_total[$__interval]))
sum by (route) (rate(x_total[$__rate_interval]))
# latency quantile from a histogram
histogram_quantile(0.95, sum by (route, le) (rate(x_bucket[$__rate_interval])))
# time since a systemd timer fired
time() - node_systemd_timer_last_trigger_seconds{name="foo.timer"}
```

## 4. Verify (before showing the user)

```bash
$ just grafana-queries --from now-7d scratch-<name>
$ just grafana-screenshot scratch-<name> --from now-7d --expand -o tmp/<name>/full.png
$ just grafana-screenshot scratch-<name> --panel 14 -o tmp/<name>/p14.png
```

- No `FAIL`. Explain every `EMPTY` (idle metric -> `noValue`; else fix).
- Read the PNGs. Check: tile values plausible, legends not truncated, colors
  match status meaning, no near-empty panels, bars readable, row heights
  balanced. Tall full-page shots get downscaled when read; use `--panel ID`
  (element `.spec.id`) for detail.
- The default `--width` (2172) renders the panel layout phlip9 sees on
  phlipdesk. Screenshot at the default only. W/o `--from`, shots use the
  dashboard's own default range. The default `--theme` is phlip9's Grafana
  theme (`gildedgrove`: `#1d2220` panels), not the stock dark theme: pick
  colors against it.
- Cross-check headline numbers against a direct `query_prometheus`.

## 5. Iterate

Share the link. The user's open tab auto-reloads on every save.

- While only you write the copy: regenerate + `just grafana-push`
  freely.
- Once anyone else saved it (the user in the UI, your own
  `update_dashboard` patches, `grafana-resave`), `grafana-push` refuses:
  it would discard those edits. Pull the copy into the file you push
  (`just grafana-promote scratch-<name> tmp/<name>/<name>.json`), switch
  to editing that file in place (see Update below), then push. `--force`
  only to discard edits on purpose.
- Sync state is per file: a file never pushed/promoted w/ the copy
  (another file, session, or worktree) is refused too. Promote into it
  first, or `--force` if the copy is stale.
- One-off tweaks: `update_dashboard` patch operations (paths in dot
  notation, ex: `$.elements.stat-up.spec.vizConfig.spec.options.colorMode`).

## 6. Promote

1. `just grafana-resave scratch-<name>`: saves the copy through the UI
   in headless Firefox, like a user clicking Save. The UI fills in panel
   defaults (`hideFrom`, `axis*`, threshold base `0`, plugin `version`,
   ...) and compacts the grid; without this, the user's first UI save of
   the real dashboard becomes a big noise diff. It keeps the copy's row
   collapse state (it opens collapsed rows so their panels get defaults,
   then closes them again).
2. `just grafana-promote scratch-<name> nixos/sauna/grafana/<name>.json`
   (new dashboard: the uid is the file stem).
3. `just grafana-check nixos/sauna/grafana/<name>.json`, show `git diff
   --stat`, commit: `grafana: <name>: <change>`. Don't push unless asked;
   a push to `master` makes Git Sync create/update the real dashboard.

## Update an existing dashboard

The committed manifest is the source of truth (UI saves land in it via Git
Sync; old generator scripts are gone): edit it in place, never regenerate it.

1. Resave first, as its own commit. A UI save after a Grafana upgrade
   rewrites plugin `version`s, fills new defaults, and compacts the grid.
   Commit that churn alone, so the real change's diff is only the edit:

   ```bash
   $ just grafana-push --force nixos/sauna/grafana/<x>.json
   $ just grafana-resave scratch-<x>
   $ just grafana-promote scratch-<x> nixos/sauna/grafana/<x>.json
   $ git diff --stat   # empty: nothing to commit
   $ nix eval --raw -f . nixosConfigs.sauna.config.services.grafana.package.version
   ```

   Commit: `grafana: <x>: resave w/ Grafana <version>`.
2. Map it: `just grafana-outline --queries nixos/sauna/grafana/<x>.json`.
   Panel details: `jq '.spec.elements["panel-15"]' FILE`. New metrics:
   Discover (step 1) first.
3. Edit w/ a throwaway `tmp/<x>/edit.py`:

   ```python
   import sys
   sys.path.insert(0, ".agents/skills/grafana-dashboard/scripts")
   from dash import Dashboard, pos_delta, thresholds

   d = Dashboard.load("nixos/sauna/grafana/<x>.json")
   d.query("Total requests")["expr"] = "..."  # element key or unique title
   d.find("panel-10")["description"] = "..."  # panel spec, edit in place
   ts = d.timeseries("ts-req-rate", ...)      # same builders as new ones
   d.extend_row("Metrics", [(8, [(ts, 24)])]) # below the row's panels
   d.remove("panel-12")                       # + its layout items
   d.write("nixos/sauna/grafana/<x>.json")
   ```

   - `write` keeps Grafana's formatting: `git diff` shows only your edits.
   - `remove` leaves a hole: widen/move neighbors (layout item `spec`).
   - Match the dashboard's existing style (units, legends, key names) over
     the conventions above.
   - Viz types w/o a builder (gauge, bargauge, table, ...): copy an
     existing panel of that type (`node-exporter-full.json` has most) and
     edit it. Don't guess option names: Grafana ignores unknown ones.
4. Check: `just grafana-check FILE`, `just grafana-queries FILE`, `git
   diff`.
5. Visual changes (new/re-laid-out panels, viz options, annotations): `just
   grafana-push FILE`, then screenshot `scratch-<x>` as in Verify. If the
   user edits the Scratch copy, `just grafana-promote scratch-<x> FILE`
   before your next edit script.
6. Commit the manifest: `grafana: <x>: <change>`. New panels: push,
   `just grafana-resave scratch-<x>`, and promote back into FILE first
   (Promote steps 1-2); after step 1, that diff is only your edit.

## Profiles

Continuous profiling: Alloy eBPF samples every process on sauna -> Pyroscope.

- Datasource: `{"type": "grafana-pyroscope-datasource", "uid":
  "pyroscope"}`. `pyroscope` is the `data_source_uid` for the mcp tools.
- Profile type ids:
  - on-CPU (49 Hz): `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
  - off-CPU (blocked time, sampled): `offcpu:offcpu:nanoseconds::`
- Labels: `service_name` = systemd unit (`nginx`, `nix-daemon`,
  `getty@` for templates, `user-<name>` for sessions, `systemd` = PID 1,
  `ebpf/unspecified` = kernel threads + procs younger than one discovery
  scan), `exe` = exe basename (`.foo-wrapped` -> `foo`), `host`. No pid.
- UI: Profiles Drilldown,
  `https://grafana.phlip9.com/a/grafana-pyroscope-app/explore?explorationType=flame-graph&var-dataSource=pyroscope&var-serviceName=<unit>&var-profileMetricId=<type id>`
  (+ `&from=..&to=..`; `explorationType=all` = service list). One unit
  only.
- mcp tools (`pyroscope` group):
  - `list_pyroscope_profile_types {data_source_uid}`
  - `list_pyroscope_label_names` / `list_pyroscope_label_values {name}`,
    `matchers` ex: `{service_name="nix-daemon"}`
  - `query_pyroscope {data_source_uid, profile_type, matchers, query_type:
    "profile"|"metrics"|"both", group_by, max_node_depth}`: `profile` =
    top-N fns flat/cum table (`format: "dot"` = call graph), `metrics` =
    time series (ex: `group_by: ["exe"]`).
  - times: `start_rfc_3339`/`end_rfc_3339`, default last 1h.
- Panel query (viz `flamegraph` w/ `queryType: "profile"`, or `timeseries`
  w/ `"metrics"`): `{"kind": "DataQuery", "group":
  "grafana-pyroscope-datasource", "version": "v0", "datasource": {"name":
  "pyroscope"}, "spec": {"queryType": "profile", "profileTypeId": "...",
  "labelSelector": "{service_name=\"nginx\"}", "groupBy": [], "maxNodes":
  16384}}`. Reference: `nixos/sauna/grafana/profiling.json`.
  - `metrics`: `groupBy: ["exe"]` + `limit: 10` = top-10 series; values in
    `cores` (CPU s/s); no point when a series has no samples (gaps, not
    0). Set `queryOptions.interval` (ex: `1m`), else the step is
    `minStep` 15s.
  - `profile`: `maxNodes` truncates into `other` nodes; whole-host
    profiles are huge (16384 nodes -> ~50% `other`), per unit is fine.
  - Variables: label-values query variable, spec `{"type": "labelValue",
    "profileTypeId": "...", "labelName": "service_name"}` (also
    `profileType`, `label`).
  - The DS doesn't escape variables: use `service_name=~"${var:raw}"` w/
    `allValue: ".+"`. `:regex` breaks: the selector parser rejects its
    `\/` (`ebpf\/unspecified`).
- Health metrics (VictoriaMetrics): jobs `alloy` + `pyroscope`,
  `pyroscope_write_*`, `pyroscope_ebpf_*`, `pyroscope_data_bytes`,
  `pyroscope_distributor_*`. `pyroscope_write_dropped_profiles_total` only
  exists after the first drop (`or vector(0)`).
- Don't query huge `maxNodes` (>= 1e6) by hand: Pyroscope RSS jumps to
  ~1 GiB.

## Gotchas

- `get_dashboard_property` needs bracket-quoted names w/ dashes:
  `$.elements["stat-up"]`; `update_dashboard` patch paths use dot notation.
  Add a panel: `$.elements.panel-99` + append its item to
  `$.layout.spec.rows[1].spec.layout.spec.items/-`.
- `/api/ds/query` expands `$__interval` etc. server-side but not dashboard
  variables; `grafana-queries` substitutes saved `current` values.
- No Grafana image renderer: `/render/...` returns 500. Use
  `grafana-screenshot`.
- `grafana-resave` only opens collapsed rows: panels on inactive tabs
  (TabsLayout) don't get their defaults filled in.
- A resave changes the copy: promote before the next push, else
  `grafana-push` refuses.
- `byRegexp` override matchers are anchored (`^...$`) unless written
  `/.../`: `" max$"` matches nothing, `".+ max"` works.
- state-timeline w/ `mergeValues` + `color.mode: "thresholds"` buckets
  values by threshold (tooltip "1+") and ignores value mappings. Use
  `color.mode: "fixed"` + mappings w/ colors for labeled states.
- Timeline `fillOpacity` replaces a color's own alpha: `rgba(...)` colors
  come out opaque-ish. For an exact shade, use an opaque hex at
  `fillOpacity: 100`.
- Compact tiles: one stat panel w/ one query per tile (legend = tile name),
  `textMode: "value_and_name"`, `wideLayout: false` (else wide tiles put
  the name beside the value), `graphMode: "none"`, fixed `text` sizes.
  Per-tile links/units/mappings: `byName` overrides.
- Text tiles (versions, kernel): instant query w/ `format: "table"`, a
  label as the value (`label_keep(label_copy(x, "release", "kernel"),
  "kernel")`), picked by `reduceOptions.fields: "/^(kernel|...)$/"`.
  Grafana builds table frames after plain series: in a mixed panel, the
  numeric tiles come first.

## Improve this skill

At the end, note friction you hit (missing tool, wrong default, unclear
step) and propose or make the fix here, in `scripts/dash.py`, or in
`just/grafana-*.sh` (shared jq defs: `just/grafana.jq`).
