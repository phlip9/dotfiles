"""Tiny builder/editor for Grafana 13 v2 dashboard specs (VictoriaMetrics).

Emits minimal, valid v2 JSON so agents don't hand-write 40 panels of
boilerplate. Grafana's UI fills in its defaults on the next UI save.

new dashboard (from the repo root, in a throwaway tmp/<name>/gen.py):

    import sys
    sys.path.insert(0, ".agents/skills/grafana-dashboard/scripts")
    from dash import Dashboard, add_matcher, pos_delta, thresholds

    d = Dashboard("Nix CI", tags=["ci"], time_from="now-7d")
    d.follow_overview()  # $instance, annotations, nav: like the others
    up = d.stat("stat-up", "nixbot", "Scrape status.",
                'up{job="nixbot", instance=~"$instance"}',
                mappings=d.UP_MAP, color_mode="background_solid",
                thr=d.UP_THR, graph=False)
    rate = d.timeseries("ts-rate", "Requests", "Req rate by route.",
                        [(add_matcher("sum by (route) "
                                      "(rate(x[$__rate_interval]))"),
                          "{{route}}")], unit="reqps")
    d.row("Overview", [(4, [(up, 4)]), (8, [(rate, 24)])])
    d.write("tmp/nix-ci/nix-ci.json", uid="nix-ci")  # Git Sync manifest

then: just grafana-push tmp/nix-ci/nix-ci.json scratch-nix-ci

update an existing dashboard in place (tmp/<name>/edit.py; find keys w/
`just grafana-outline FILE`):

    d = Dashboard.load("nixos/sauna/grafana/nginx.json")
    d.query("Total requests")["expr"] = "sum(rate(x[$__rate_interval]))"
    d.find("panel-10")["description"] = "Accepted vs handled conns/s."
    ts = d.timeseries("ts-req-rate", "Request rate", "...", [(expr, "")])
    d.extend_row("Metrics", [(8, [(ts, 24)])])
    d.remove("panel-12")
    d.write("nixos/sauna/grafana/nginx.json")

`write` emits Grafana's own formatting, so the git diff shows only the
edits.
"""

import copy
import json
import os
import re
from collections.abc import Sequence
from typing import Any, ClassVar, Literal, Self

GROUP = "victoriametrics-metrics-datasource"
DS_VAR = "DS_PROMETHEUS"
# Source of truth for the conventions every dashboard shares
# (`Dashboard.follow_overview`). Paths are relative to the repo root.
OVERVIEW = "nixos/sauna/grafana/overview.json"
# Tag on every dashboard; its "Dashboards" dropdown link lists them.
NAV_TAG = "o11y"
# Series selector filter for the shared `$instance` var.
INSTANCE_MATCHER = 'instance=~"$instance"'

# A JSON object, ex: a spec or panel. Grafana's v2 schema is too big to type
# here, so its values are `Any`.
JsonObj = dict[str, Any]
# Any JSON value.
Json = JsonObj | list[Any] | str | float | bool | None
# A query: (expr, legendFormat).
Query = tuple[str, str]
# A layout line: (height, [(element key, width), ...]).
Line = tuple[int, Sequence[tuple[str, int]]]
# A threshold step: (color, value); the first value is None (-inf).
Step = tuple[str, float | None]


def pos_delta(selector: str, window: str = "$__interval") -> str:
    """Sum of positive 1m steps of a gauge over `window`.

    For "counters" exported as gauges that also shrink (ex: DB row counts w/
    retention cleanup): `increase()` reads a shrink as a counter reset and
    over-counts. Needs a 1m scrape interval and panel steps >= 1m.
    """
    return f"sum_over_time(clamp_min(delta({selector}[1m]), 0)[{window}:1m])"


def thresholds(*steps: Step) -> JsonObj:
    """Absolute thresholds from (color, value) pairs; first value None."""
    return {
        "mode": "absolute",
        "steps": [{"color": c, "value": v} for c, v in steps],
    }


def color(name: str, fixed: str) -> JsonObj:
    """Override: series `name` gets a fixed color."""
    return {
        "matcher": {"id": "byName", "options": name},
        "properties": [
            {"id": "color", "value": {"mode": "fixed", "fixedColor": fixed}}
        ],
    }


def hidden(name: str) -> JsonObj:
    """Override: hide series `name` from the plot until its legend is
    clicked."""
    return {
        "matcher": {"id": "byName", "options": name},
        "properties": [
            {
                "id": "custom.hideFrom",
                "value": {"legend": False, "tooltip": False, "viz": True},
            }
        ],
    }


# Final-status colors. Status colors mean state; never reuse them for
# unrelated series.
STATUS_COLORS: list[JsonObj] = [
    color("succeeded", "green"),
    color("ok", "green"),
    color("done", "green"),
    color("failed", "red"),
    color("error", "red"),
    color("cancelled", "#8e8e8e"),
    color("skipped", "#8e8e8e"),
]

# Event-count bar charts: >= 1h buckets keep sparse events readable.
BARS: JsonObj = {"interval": "1h", "maxDataPoints": 200}


# --- add_matcher --- #

# Keywords followed by a parenthesized label list, not an expression.
_GROUPING = {"by", "without", "on", "ignoring", "group_left", "group_right"}
# Other bare words that aren't metric names.
_KEYWORDS = {"bool", "and", "or", "unless", "offset", "atan2", "inf", "nan",
             "keep_metric_names", "default", "if", "ifnot", "limit"}
_IDENT = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:.]*")
_NUMBER = re.compile(r"\d[\d.]*([eE][+-]?\d+)?[a-zA-Z]*")
_VAR = re.compile(r"\$(\{[^}]*\}|\w+)")
_AGG = re.compile(r"(by|without)\s*\(", re.IGNORECASE)
# A quoted label value (any PromQL quote style, w/ escapes).
_QUOTED = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`[^`]*`')


def _string_end(expr: str, i: int) -> int:
    """Index after the quoted string starting at `i`."""
    quote, j = expr[i], i + 1
    while expr[j] != quote:
        j += 2 if expr[j] == "\\" else 1
    return j + 1


def _close(expr: str, i: int, open_: str, close: str) -> int:
    """Index after the `close` matching `open_` at `i` (strings skipped)."""
    depth, j = 0, i
    while True:
        char = expr[j]
        if char in "\"'`":
            j = _string_end(expr, j)
            continue
        depth += (char == open_) - (char == close)
        j += 1
        if depth == 0:
            return j


def _with_matcher(braces: str, matcher: str) -> str:
    """`{...}` selector w/ `matcher` appended, unless it already has a
    matcher on the same label (label names only, not quoted values)."""
    label = matcher.split("=")[0].rstrip("!~ ")
    names = _QUOTED.sub('""', braces)
    if re.search(r"(^|[{,\s])" + re.escape(label) + r"\s*[!=]", names):
        return braces
    # A trailing comma (`{a="b",}`) is valid: don't double it.
    inner = braces[1:-1].strip().removesuffix(",").rstrip()
    return "{" + (inner + ", " if inner else "") + matcher + "}"


def add_matcher(expr: str, matcher: str = INSTANCE_MATCHER) -> str:
    """PromQL/MetricsQL `expr` w/ `matcher` added to every series selector
    (ex: an upstream dashboard's queries -> filtered by `$instance`).
    Keeps the rest of the text (formatting, `#` comments) as is; idempotent.
    Not for `label_values(metric, label)` variable queries: their label arg
    isn't a selector. Raises ValueError on MetricsQL `WITH (...)` templates:
    it can't tell template names from metric names.

    >>> add_matcher('sum by (le) (rate(x{a="b"}[5m])) / y')
    'sum by (le) (rate(x{a="b", instance=~"$instance"}[5m])) / y{instance=~"$instance"}'
    """
    out: list[str] = []
    i, end = 0, len(expr)
    while i < end:
        char = expr[i]
        if char in "\"'`":
            j = _string_end(expr, i)
            out.append(expr[i:j])
        elif char == "#":  # comment to end of line
            j = expr.find("\n", i)
            j = end if j < 0 else j
            out.append(expr[i:j])
        elif char == "[":  # range / subquery window
            j = expr.index("]", i) + 1
            out.append(expr[i:j])
        elif char == "{":  # selector w/o metric name
            j = _close(expr, i, "{", "}")
            out.append(_with_matcher(expr[i:j], matcher))
        elif char == "$" and (m := _VAR.match(expr, i)):
            j = m.end()
            out.append(m.group())
        elif char.isdigit() and (m := _NUMBER.match(expr, i)):
            j = m.end()
            out.append(m.group())
        elif m := _IDENT.match(expr, i):
            word, j = m.group(), m.end()
            k = j
            while k < end and expr[k].isspace():
                k += 1
            nxt = expr[k] if k < end else ""
            low = word.lower()
            if low == "with" and nxt == "(":
                raise ValueError(f"add_matcher: WITH templates unsupported: "
                                 f"{expr!r}")
            if low in _GROUPING and nxt == "(":  # label list
                j = _close(expr, k, "(", ")")
                out.append(expr[i:j])
            elif (low in _KEYWORDS or low in _GROUPING or nxt == "("
                  or _AGG.match(expr, k)):  # keyword, fn, `sum by (..)`
                out.append(word)
            elif nxt == "{":
                j = _close(expr, k, "{", "}")
                out.append(word + expr[m.end():k]
                           + _with_matcher(expr[k:j], matcher))
            else:  # bare metric name
                out.append(word + "{" + matcher + "}")
        else:
            j = i + 1
            out.append(char)
        i = j
    return "".join(out)


def go_json(obj: Json) -> str:
    """JSON text formatted like Grafana Git Sync writes it (Go
    encoding/json): sorted keys, 2-space indent, raw UTF-8 but `<>&` and
    U+2028/2029 escaped, no trailing newline. Re-emitting an unchanged
    manifest is byte-identical."""
    text = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False)
    # These chars only occur inside JSON strings, so plain replace is safe.
    for char, esc in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"),
                      ("\u2028", "\\u2028"), ("\u2029", "\\u2029")):
        text = text.replace(char, esc)
    return text


def element_refs(layout: Json) -> list[str]:
    """All element names referenced anywhere in a v2 layout tree."""
    if isinstance(layout, dict):
        if layout.get("kind") == "ElementReference":
            return [layout["name"]]
        return [ref for val in layout.values() for ref in element_refs(val)]
    if isinstance(layout, list):
        return [ref for val in layout for ref in element_refs(val)]
    return []


def drop_refs(layout: Json, key: str) -> None:
    """Remove every layout item that references element `key`, in place."""
    if isinstance(layout, dict):
        items = layout.get("items")
        if isinstance(items, list):
            items[:] = [
                item for item in items
                if item.get("spec", {}).get("element", {}).get("name") != key
            ]
        for val in layout.values():
            drop_refs(val, key)
    elif isinstance(layout, list):
        for val in layout:
            drop_refs(val, key)


class Dashboard:
    """A v2 dashboard spec under construction or edit.

    `Dashboard(title, ...)` starts a new one; `Dashboard.load(path)` opens an
    existing manifest. Both hold the whole spec in `self.data`, so the panel
    builders, lookups, and layout helpers work the same on either.
    `spec()` / `write()` validate + emit it.
    """

    # `up`-style status tiles: neutral when healthy (UP unfilled), color only
    # for anomalies. No data (no series, or null) is UNKNOWN, never healthy.
    # Use w/ color_mode="background_solid" + thr=UP_THR.
    UP_MAP: ClassVar[list[JsonObj]] = [
        {
            "type": "value",
            "options": {
                "0": {"text": "DOWN", "color": "dark-red", "index": 0},
                "1": {"text": "UP", "color": "transparent", "index": 1},
            },
        },
        {
            "type": "special",
            "options": {
                "match": "null+nan",
                "result": {"text": "UNKNOWN", "color": "dark-purple",
                           "index": 2},
            },
        },
    ]
    UP_THR: ClassVar[JsonObj] = thresholds(("dark-red", None),
                                           ("transparent", 1))

    def __init__(self, title: str, description: str = "",
                 tags: Sequence[str] = (), time_from: str = "now-24h",
                 refresh: str = "1m") -> None:
        # Git Sync manifest wrapper ({apiVersion, kind, metadata}), if loaded
        # from one.
        self.manifest: JsonObj | None = None
        # The v2 dashboard spec.
        self.data: JsonObj = {
            "title": title,
            "description": description,
            "tags": list(tags),
            "editable": True,
            "cursorSync": "Crosshair",
            "preload": False,
            "liveNow": False,
            "links": [],
            "annotations": [{
                "kind": "AnnotationQuery",
                "spec": {
                    "builtIn": True,
                    "enable": True,
                    "hide": True,
                    "iconColor": "rgba(0, 211, 255, 1)",
                    "name": "Annotations & Alerts",
                    "query": {
                        "group": "grafana", "kind": "DataQuery",
                        "spec": {}, "version": "v0",
                    },
                },
            }],
            "timeSettings": {
                "from": time_from,
                "to": "now",
                "autoRefresh": refresh,
                "autoRefreshIntervals": [
                    "30s", "1m", "5m", "15m", "30m", "1h",
                ],
                "fiscalYearStartMonth": 0,
                "hideTimepicker": False,
                "timezone": "browser",
            },
            "variables": [{
                "kind": "DatasourceVariable",
                "spec": {
                    "name": DS_VAR,
                    "label": "datasource",
                    "pluginId": GROUP,
                    "current": {
                        "text": "VictoriaMetrics (Plugin)",
                        "value": "victoriametrics",
                    },
                    "hide": "dontHide",
                    "refresh": "onDashboardLoad",
                    "regex": "",
                    "options": [],
                    "multi": False,
                    "includeAll": False,
                    "allowCustomValue": True,
                    "skipUrlSync": False,
                },
            }],
            "elements": {},
            "layout": {"kind": "RowsLayout", "spec": {"rows": []}},
        }

    @classmethod
    def load(cls, path: str | os.PathLike[str]) -> Self:
        """Open a Git Sync manifest (or bare v2 spec) file for editing.
        Edits mutate the loaded JSON; everything else is kept as is."""
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
        if not isinstance(obj, dict):
            raise ValueError(f"{path}: not a JSON object")
        self = cls.__new__(cls)
        if "apiVersion" in obj and "spec" in obj:
            self.manifest, self.data = obj, obj["spec"]
        else:
            self.manifest, self.data = None, obj
        if not isinstance(self.data.get("elements"), dict) \
                or "layout" not in self.data:
            raise ValueError(f"{path}: not a v2 dashboard spec")
        return self

    @property
    def elements(self) -> dict[str, JsonObj]:
        """{key: element} of the spec (live)."""
        return self.data["elements"]

    @property
    def variables(self) -> list[JsonObj]:
        """Variable list of the spec (live)."""
        return self.data.setdefault("variables", [])

    @property
    def rows(self) -> list[JsonObj]:
        """RowsLayout row list of the spec (live)."""
        layout = self.data["layout"]
        if layout["kind"] != "RowsLayout":
            raise ValueError(f"layout is {layout['kind']}, not RowsLayout")
        return layout["spec"]["rows"]

    # --- shared conventions --- #

    def follow_overview(self, overview: str = OVERVIEW) -> None:
        """Copy the conventions every dashboard shares from `overview`
        (the source of truth), replacing older copies; idempotent:
        `NAV_TAG` + "Dashboards" dropdown link, overview's annotations
        (reboots, deploys, alerts, OOM kills), the `$instance` var right
        after the datasource var, refresh choices, shared crosshair.
        Queries still need `INSTANCE_MATCHER` (see `add_matcher`)."""
        ov = Dashboard.load(overview).data
        spec = self.data
        # Loaded bare specs may omit any of these.
        for key, default in (("tags", []), ("links", []),
                             ("annotations", []), ("timeSettings", {})):
            spec.setdefault(key, default)
        if NAV_TAG not in spec["tags"]:
            spec["tags"].append(NAV_TAG)

        nav = next(link for link in ov["links"] if link["type"] == "dashboards")
        spec["links"] = [copy.deepcopy(nav)] + [
            link for link in spec["links"] if link["type"] != "dashboards"]

        # Built-in "Annotations & Alerts" first, then overview's, then ours.
        shared = [a for a in ov["annotations"] if not a["spec"].get("builtIn")]
        names = {a["spec"]["name"] for a in shared}
        own = [a for a in spec["annotations"] if a["spec"]["name"] not in names]
        builtin = [a for a in own if a["spec"].get("builtIn")]
        rest = [a for a in own if not a["spec"].get("builtIn")]
        spec["annotations"] = builtin + copy.deepcopy(shared) + rest

        inst = next(v for v in ov["variables"]
                    if v["spec"]["name"] == "instance")
        variables = [v for v in self.variables
                     if v["spec"]["name"] != "instance"]
        # Right after the datasource var, else first (fixed datasource).
        ds_idx = next((i for i, v in enumerate(variables)
                       if v["kind"] == "DatasourceVariable"), -1)
        variables.insert(ds_idx + 1, copy.deepcopy(inst))
        spec["variables"] = variables

        ts, ov_ts = spec["timeSettings"], ov["timeSettings"]
        ts["autoRefresh"] = ov_ts["autoRefresh"]
        ts["autoRefreshIntervals"] = list(ov_ts["autoRefreshIntervals"])
        spec["cursorSync"] = ov["cursorSync"]

    # --- lookup --- #

    def key(self, ref: str) -> str:
        """Element key of `ref`: an element key, or a unique panel title."""
        if ref in self.elements:
            return ref
        keys = [key for key, el in self.elements.items()
                if el["spec"].get("title") == ref]
        if len(keys) != 1:
            raise KeyError(f"{ref!r}: {len(keys)} elements w/ that title")
        return keys[0]

    def find(self, ref: str) -> JsonObj:
        """Panel spec (title, description, data, vizConfig, ...) of `ref`,
        for in-place edits."""
        return self.elements[self.key(ref)]["spec"]

    def query(self, ref: str, ref_id: str = "A") -> JsonObj:
        """Query spec ({expr, legendFormat, ...}) of panel `ref`'s query
        `ref_id`, for in-place edits."""
        for query in self.find(ref)["data"]["spec"]["queries"]:
            if query["spec"]["refId"] == ref_id:
                return query["spec"]["query"]["spec"]
        raise KeyError(f"{ref!r}: no query {ref_id}")

    def remove(self, ref: str) -> None:
        """Delete panel `ref` and every layout item placing it."""
        key = self.key(ref)
        del self.elements[key]
        drop_refs(self.data["layout"], key)

    # --- queries --- #

    @staticmethod
    def queries(items: Sequence[Query], instant: bool = False) -> list[JsonObj]:
        """[(expr, legend), ...] -> v2 PanelQuery list (refIds A, B, ...)."""
        out: list[JsonObj] = []
        for i, (expr, legend) in enumerate(items):
            out.append({
                "kind": "PanelQuery",
                "spec": {
                    "refId": chr(ord("A") + i),
                    "hidden": False,
                    "query": {
                        "kind": "DataQuery",
                        "group": GROUP,
                        "version": "v0",
                        "datasource": {"name": "${" + DS_VAR + "}"},
                        "spec": {
                            "expr": expr,
                            "legendFormat": legend,
                            "instant": instant,
                            "range": not instant,
                        },
                    },
                },
            })
        return out

    # --- panels --- #

    def panel(self, key: str, title: str, desc: str, viz: str,
              queries: list[JsonObj], defaults: JsonObj, options: JsonObj,
              overrides: Sequence[JsonObj] = (),
              qopts: JsonObj | None = None) -> str:
        """Add a raw v2 panel element; returns `key` for layouts."""
        if key in self.elements:
            raise ValueError(f"duplicate element {key}")
        # Panel ids must be unique: max + 1, also on loaded dashboards.
        next_id = 1 + max(
            (el["spec"].get("id", 0) for el in self.elements.values()),
            default=0,
        )
        self.elements[key] = {
            "kind": "Panel",
            "spec": {
                "id": next_id,
                "title": title,
                "description": desc,
                "links": [],
                "data": {
                    "kind": "QueryGroup",
                    "spec": {
                        "queries": queries,
                        "queryOptions": qopts or {},
                        "transformations": [],
                    },
                },
                "vizConfig": {
                    "kind": "VizConfig",
                    "group": viz,
                    "spec": {
                        "options": options,
                        "fieldConfig": {
                            "defaults": defaults,
                            "overrides": list(overrides),
                        },
                    },
                },
            },
        }
        return key

    def stat(self, key: str, title: str, desc: str, expr: str,
             unit: str = "short", thr: JsonObj | None = None,
             mappings: list[JsonObj] | None = None,
             calc: str = "lastNotNull", decimals: int | None = None,
             no_value: str | None = None,
             color_mode: Literal["value", "background", "background_solid",
                                 "none"] = "value",
             graph: bool = True) -> str:
        """Stat tile w/ a background sparkline (range query).

        `calc` reduces the series to the tile value:
        - "lastNotNull": gauges, running totals (`running_sum(...)`)
        - "sum": per-interval event counts (`increase(x[$__interval])`,
          `pos_delta(x)`) -> total over the dashboard range
        Steps are >= 1m so `pos_delta` subqueries tile the range.
        """
        defaults: JsonObj = {
            "unit": unit,
            "color": {"mode": "thresholds"},
            "thresholds": thr or thresholds(("text", None)),
            "mappings": mappings or [],
        }
        if decimals is not None:
            defaults["decimals"] = decimals
        if no_value is not None:
            defaults["noValue"] = no_value
        options = {
            "reduceOptions": {
                "calcs": [calc], "fields": "", "values": False,
            },
            "colorMode": color_mode,
            "graphMode": "area" if graph else "none",
            "justifyMode": "center",
            "textMode": "value",
            "orientation": "auto",
            "wideLayout": True,
            "showPercentChange": False,
        }
        return self.panel(key, title, desc, "stat",
                          self.queries([(expr, "")]), defaults, options,
                          qopts={"interval": "1m", "maxDataPoints": 100})

    def timeseries(self, key: str, title: str, desc: str,
                   items: Sequence[Query], unit: str = "short",
                   bars: bool = False, stack: bool = False,
                   overrides: Sequence[JsonObj] = (),
                   qopts: JsonObj | None = None, decimals: int | None = None,
                   min0: bool = True,
                   points: Literal["auto", "always", "never"] = "never",
                   log: bool = False,
                   legend_calcs: Sequence[str] = ("max", "mean"),
                   no_value: str | None = None,
                   max: float | None = None) -> str:
        """Time series panel. `items`: [(expr, legend), ...].

        bars=True: event counts per interval; pass qopts=BARS and use
        `increase(x[$__interval])` / `pos_delta(x)` + legend_calcs=("sum",).
        Legend w/ calcs = table on the right; () = plain list at the bottom.
        """
        custom = {
            "drawStyle": "bars" if bars else "line",
            "lineWidth": 1 if bars else 2,
            "fillOpacity": 80 if bars else 10,
            "gradientMode": "none",
            "showPoints": points,
            "pointSize": 6,
            "spanNulls": False,
            "lineInterpolation": "linear",
            "barAlignment": 1,
            "axisPlacement": "auto",
            "axisLabel": "",
            "stacking": {"group": "A", "mode": "normal" if stack else "none"},
            "scaleDistribution": (
                {"type": "log", "log": 10} if log else {"type": "linear"}
            ),
            "thresholdsStyle": {"mode": "off"},
        }
        defaults: JsonObj = {
            "unit": unit,
            "color": {"mode": "palette-classic"},
            "custom": custom,
            "thresholds": thresholds(("green", None)),
        }
        if min0 and not log:
            defaults["min"] = 0
        if max is not None:
            defaults["max"] = max
        if decimals is not None:
            defaults["decimals"] = decimals
        if no_value is not None:
            defaults["noValue"] = no_value
        options = {
            "legend": {
                "showLegend": True,
                "displayMode": "table" if legend_calcs else "list",
                "placement": "right" if legend_calcs else "bottom",
                "calcs": list(legend_calcs),
            },
            "tooltip": {"mode": "multi", "sort": "desc", "hideZeros": stack},
        }
        if bars and qopts is None:
            qopts = BARS
        return self.panel(key, title, desc, "timeseries",
                          self.queries(items), defaults, options, overrides,
                          qopts)

    # --- layout --- #

    def grid_items(self, lines: Sequence[Line], y: int = 0) -> list[JsonObj]:
        """GridLayout items for `lines`: [(height, [(key, width), ...])],
        stacked from row offset `y`. Widths per line should sum to 24."""
        items: list[JsonObj] = []
        for height, line in lines:
            x = 0
            for key, width in line:
                if key not in self.elements:
                    raise ValueError(f"unknown element {key}")
                items.append({
                    "kind": "GridLayoutItem",
                    "spec": {
                        "x": x, "y": y, "width": width, "height": height,
                        "element": {"kind": "ElementReference", "name": key},
                    },
                })
                x += width
            if x > 24:
                raise ValueError(f"line wider than 24: {line}")
            y += height
        return items

    def row(self, title: str, lines: Sequence[Line],
            collapse: bool = False) -> None:
        """Add a RowsLayout row w/ a GridLayout of `lines` (see
        `grid_items`)."""
        self.rows.append({
            "kind": "RowsLayoutRow",
            "spec": {
                "title": title,
                "collapse": collapse,
                "layout": {
                    "kind": "GridLayout",
                    "spec": {"items": self.grid_items(lines)},
                },
            },
        })

    def extend_row(self, title: str, lines: Sequence[Line]) -> None:
        """Append `lines` (see `grid_items`) below the existing panels of
        row `title`."""
        rows = [row["spec"] for row in self.rows
                if row["spec"].get("title") == title]
        if len(rows) != 1:
            raise KeyError(f"{title!r}: {len(rows)} rows w/ that title")
        layout = rows[0]["layout"]
        if layout["kind"] != "GridLayout":
            raise ValueError(f"row {title!r}: {layout['kind']}, not GridLayout")
        items = layout["spec"].setdefault("items", [])
        bottom = max(
            (item["spec"]["y"] + item["spec"]["height"] for item in items),
            default=0,
        )
        items.extend(self.grid_items(lines, y=bottom))

    # --- output --- #

    def spec(self) -> JsonObj:
        """The validated v2 spec: every element placed, every layout ref
        resolves."""
        refs = element_refs(self.data["layout"])
        unknown = set(refs) - set(self.elements)
        if unknown:
            raise ValueError(f"layout refs unknown elements: {sorted(unknown)}")
        unplaced = set(self.elements) - set(refs)
        if unplaced:
            raise ValueError(f"elements not in the layout: {sorted(unplaced)}")
        return self.data

    def write(self, path: str | os.PathLike[str],
              uid: str | None = None) -> None:
        """Write a Git Sync manifest (needed by `just grafana-check`) if
        loaded from one or `uid` is given (overrides the loaded uid), else
        the bare spec. Formatted by `go_json`."""
        out = self.spec()
        if self.manifest is not None or uid is not None:
            manifest: JsonObj = self.manifest or {
                "apiVersion": "dashboard.grafana.app/v2",
                "kind": "Dashboard",
                "metadata": {},
            }
            out = dict(manifest)
            out["metadata"] = dict(out["metadata"])
            if uid is not None:
                out["metadata"]["name"] = uid
            out["spec"] = self.data
        with open(path, "w", encoding="utf-8") as f:
            f.write(go_json(out))
