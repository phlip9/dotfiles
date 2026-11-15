"""Fail if a Grafana plugin's `grafanaDependency` excludes our Grafana.

Usage: grafana-plugins-check <grafana-version> <plugin-dir>...

Ranges use the npm semver subset grafana.com plugins publish, ex:
`>=11.6.11-0 <12 || >=12.0.10-0 <12.1 || >=13.2.0-0`. Prerelease tags are
ignored, since our Grafana is a release. Unknown syntax (`^`, `~`, `x`)
fails loudly instead of passing.
"""

import json
import re
import sys
from pathlib import Path

Version = tuple[int, int, int]

# `<op>X[.Y[.Z]][-pre]`
COMPARATOR = re.compile(
    r"^(>=|<=|>|<|=)?v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(-.*)?$"
)


def parse_version(text: str) -> Version:
    """Parse `X.Y.Z[-pre]`, dropping the prerelease tag."""
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", text)
    if match is None:
        raise ValueError(f"bad version: {text!r}")
    major, minor, patch = match.groups()
    return (int(major), int(minor), int(patch))


def comparator_ok(version: Version, comparator: str) -> bool:
    """Check one `<op><version>` comparator. Missing parts count as 0."""
    match = COMPARATOR.match(comparator)
    if match is None:
        raise ValueError(f"unsupported comparator: {comparator!r}")
    op, major, minor, patch, _pre = match.groups()
    bound = (int(major), int(minor or 0), int(patch or 0))
    match op or "=":
        case ">=":
            return version >= bound
        case "<=":
            return version <= bound
        case ">":
            return version > bound
        case "<":
            return version < bound
        case _:
            return version == bound


def range_ok(version: Version, spec: str) -> bool:
    """`a b || c` = (a and b) or c."""
    return any(
        all(comparator_ok(version, comp) for comp in clause.split())
        for clause in spec.split("||")
    )


def main() -> int:
    grafana = parse_version(sys.argv[1])
    failed = False
    for plugin_dir in map(Path, sys.argv[2:]):
        plugin_json = json.loads((plugin_dir / "plugin.json").read_text())
        plugin_id = plugin_json["id"]
        spec = plugin_json.get("dependencies", {}).get("grafanaDependency")
        if not spec:
            continue
        if not range_ok(grafana, spec):
            print(
                f"error: plugin {plugin_id} requires Grafana {spec!r}, "
                f"have {sys.argv[1]}",
                file=sys.stderr,
            )
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
