"""Tests for dash.py. Run from the repo root: just grafana-test"""

import copy
import glob
import unittest

from dash import NAV_TAG, Dashboard, add_matcher, go_json

# (expr, add_matcher(expr)) pairs.
MATCHER_CASES: list[tuple[str, str]] = [
    ("up", 'up{instance=~"$instance"}'),
    ('up{job="x"}', 'up{job="x", instance=~"$instance"}'),
    ('up{job="x", instance="a"}', 'up{job="x", instance="a"}'),
    ('{job="x"}', '{job="x", instance=~"$instance"}'),
    # Braces inside label values, grouping label lists.
    ('sum by (le) (rate(x{r!="GET /a/{id}"}[$__rate_interval]))',
     'sum by (le) (rate(x{r!="GET /a/{id}", instance=~"$instance"}'
     '[$__rate_interval]))'),
    ("1 - avg(rate(a[5m])) or vector(0)",
     '1 - avg(rate(a{instance=~"$instance"}[5m])) or vector(0)'),
    ("time() - b offset 1d > 1e9",
     'time() - b{instance=~"$instance"} offset 1d > 1e9'),
    ('label_replace(d, "a", "$1", "b", "(.*)")',
     'label_replace(d{instance=~"$instance"}, "a", "$1", "b", "(.*)")'),
    # Bare `group_left` is a keyword, not a metric.
    ("a / on(instance) group_left sum by (instance)(b)",
     'a{instance=~"$instance"} / on(instance) group_left '
     'sum by (instance)(b{instance=~"$instance"})'),
    ("max(\n  x # comment w/ y{z}\n)",
     'max(\n  x{instance=~"$instance"} # comment w/ y{z}\n)'),
    # `instance=` inside a quoted value isn't a matcher.
    ('x{note="a, instance=oops"}',
     'x{note="a, instance=oops", instance=~"$instance"}'),
    # Valid trailing comma: reused, not doubled.
    ('x{job="a",}', 'x{job="a", instance=~"$instance"}'),
]


class AddMatcherTest(unittest.TestCase):
    def test_cases(self) -> None:
        for expr, want in MATCHER_CASES:
            with self.subTest(expr=expr):
                got = add_matcher(expr)
                self.assertEqual(got, want)
                self.assertEqual(add_matcher(got), got, "not idempotent")

    def test_with_templates_rejected(self) -> None:
        with self.assertRaises(ValueError):
            add_matcher("WITH (foo = rate(x[5m])) foo")


class FollowOverviewTest(unittest.TestCase):
    def test_sparse_spec(self) -> None:
        # Bare spec w/o tags/links/annotations/timeSettings, fixed datasource
        # (no DatasourceVariable): fills them in, `$instance` first.
        d = Dashboard("t")
        for key in ("tags", "links", "annotations", "timeSettings"):
            del d.data[key]
        d.data["variables"] = []
        d.follow_overview()
        self.assertEqual(d.data["tags"], [NAV_TAG])
        self.assertEqual([v["spec"]["name"] for v in d.variables],
                         ["instance"])
        self.assertEqual([link["type"] for link in d.data["links"]],
                         ["dashboards"])
        self.assertEqual(d.data["timeSettings"]["autoRefresh"], "1m")

    def test_idempotent(self) -> None:
        d = Dashboard("t")
        d.follow_overview()
        once = copy.deepcopy(d.data)
        d.follow_overview()
        self.assertEqual(d.data, once)

    def test_dashboards_follow_overview(self) -> None:
        # Every committed dashboard already has overview's shared
        # conventions. Fails after an overview annotation/nav/var change
        # until follow_overview() is rerun on every dashboard.
        paths = sorted(glob.glob("nixos/sauna/grafana/*.json"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(path=path):
                d = Dashboard.load(path)
                d.follow_overview()
                with open(path, encoding="utf-8") as f:
                    self.assertEqual(go_json(d.manifest), f.read())


if __name__ == "__main__":
    unittest.main()
