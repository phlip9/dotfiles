"""Check the o11y inhibit rules w/ two alerted hosts in a sandbox Alertmanager.

Usage: o11y-inhibition-check <alertmanager.yml>

The config holds the inhibit rules rendered w/ `server.alerting.instances =
[ "sauna" "other" ]`, where sauna is the server. One case per source: post
the source + its targets, wait until the targets it must mute are muted
(proves the source took effect), then check that the others aren't. Then
resolve the case's alerts, so they can't affect the next case.
"""

import datetime
import json
import subprocess
import sys
import tempfile
import time
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

LISTEN = "127.0.0.1:19093"
URL = f"http://{LISTEN}"
PROBE = "https://sauna.phlip9.com/healthz"

# Every HTTP request + poll + shutdown is bounded, so nothing can hang.
REQUEST_TIMEOUT_S = 2.0
POLL_DEADLINE_S = 5.0
STOP_TIMEOUT_S = 5.0

Labels = dict[str, str]


@dataclass
class Case:
    """One inhibit source and the targets it must (not) mute."""

    name: str
    source: Labels
    muted: list[Labels]
    active: list[Labels]


def alert(name: str, severity: str, **labels: str) -> Labels:
    """Alert labels; `instance` is passed in `labels`, if any."""
    return {"alertname": name, "severity": severity, **labels}


CASES = [
    # A host source only mutes its own host's alerts, not the server's
    # host-level, service-aggregate, server-level, or probe alerts.
    Case(
        "MemLow on other",
        alert("MemLow", "page", instance="other"),
        muted=[alert("TargetDown", "warn", instance="other")],
        active=[
            alert("TargetDown", "warn", instance="sauna"),
            alert("NixbotUploadStuck", "warn", instance="sauna"),
            alert("VmalertRuleErrors", "warn", group="host"),
            alert("ProbeFailed", "warn", instance=PROBE),
        ],
    ),
    # On the server's host, it also mutes the server-level + probe alerts.
    Case(
        "MemLow on sauna",
        alert("MemLow", "page", instance="sauna"),
        muted=[
            alert("UnitFailed", "warn", instance="sauna"),
            alert("VmalertRuleErrors", "warn", group="host"),
            alert("ProbeFailed", "warn", instance=PROBE),
        ],
        active=[alert("TargetDown", "warn", instance="other")],
    ),
    Case(
        "HostRebooted on other",
        alert("HostRebooted", "info", instance="other"),
        muted=[alert("TargetDown", "warn", instance="other")],
        active=[
            alert("TargetDown", "warn", instance="sauna"),
            alert("NixbotWorkStuck", "warn", instance="sauna"),
        ],
    ),
    # Blackbox's TargetDown carries the probe URL: server-level.
    Case(
        "HostRebooted on sauna",
        alert("HostRebooted", "info", instance="sauna"),
        muted=[
            alert("TargetDown", "warn", instance="sauna"),
            alert("TargetDown", "warn", job="blackbox", instance=PROBE),
        ],
        active=[alert("TargetDown", "warn", instance="other")],
    ),
    Case(
        "PgDown on other",
        alert("PgDown", "warn", instance="other"),
        muted=[alert("NixbotWorkStuck", "warn", instance="other")],
        active=[alert("NixbotWorkStuck", "warn", instance="sauna")],
    ),
]


def fetch(path: str, body: object | None = None) -> bytes:
    """Send one request to Alertmanager, w/ a timeout. Body as JSON."""
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        URL + path, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
        return resp.read()


def request(path: str, body: object | None = None) -> Any:
    """`fetch`, w/ a JSON response."""
    raw = fetch(path, body)
    return json.loads(raw) if raw else None


def poll(check: Callable[[], bool], what: str) -> None:
    """Wait for `check()`. Alertmanager has no event to wait on, so poll."""
    deadline = time.monotonic() + POLL_DEADLINE_S
    while not check():
        if time.monotonic() > deadline:
            raise TimeoutError(f"timed out waiting for {what}")
        time.sleep(0.05)


def is_ready() -> bool:
    """Whether Alertmanager serves its API yet."""
    try:
        fetch("/-/ready")
        return True
    except OSError:
        return False


def post(alerts: list[Labels], ends_at: datetime.datetime) -> None:
    """Fire (future `ends_at`) or resolve (past `ends_at`) `alerts`."""
    request(
        "/api/v2/alerts",
        [{"labels": a, "endsAt": ends_at.isoformat()} for a in alerts],
    )


def muted_by_id() -> dict[str, bool]:
    """Alert `id` label -> whether it's inhibited, for active alerts."""
    alerts = request("/api/v2/alerts")
    return {
        a["labels"]["id"]: bool(a["status"]["inhibitedBy"])
        for a in alerts
        if "id" in a["labels"]
    }


def run_case(index: int, case: Case) -> None:
    """Check one case, then resolve its alerts."""
    # A unique `id` per alert tells the targets apart. Not an `equal` label.
    def tag(labels: Labels, kind: str, n: int) -> Labels:
        return {**labels, "id": f"{index}-{kind}-{n}"}

    source = tag(case.source, "source", 0)
    muted = [tag(a, "muted", n) for n, a in enumerate(case.muted)]
    active = [tag(a, "active", n) for n, a in enumerate(case.active)]
    alerts = [source, *muted, *active]
    now = datetime.datetime.now(datetime.timezone.utc)
    post(alerts, now + datetime.timedelta(minutes=5))

    last: dict[str, bool] = {}

    def all_muted() -> bool:
        nonlocal last
        last = muted_by_id()
        return all(last.get(a["id"], False) for a in muted)

    try:
        poll(all_muted, f"{case.name}: muted {muted}")
    except TimeoutError as err:
        raise AssertionError(f"{err}; inhibited by id: {last}") from None
    last = muted_by_id()
    wrong = [a for a in active if last.get(a["id"]) is not False]
    assert not wrong, f"{case.name}: muted or missing {wrong}; {last}"
    print(f"ok: {case.name}")

    post(alerts, now - datetime.timedelta(seconds=1))


def main() -> None:
    """Run every case against one fresh, sandbox-only Alertmanager."""
    config = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "alertmanager.log"
        with log_path.open("w") as log:
            proc = subprocess.Popen(
                [
                    "alertmanager",
                    f"--config.file={config}",
                    f"--storage.path={tmp}/data",
                    f"--web.listen-address={LISTEN}",
                    "--cluster.listen-address=",
                    "--log.level=warn",
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                poll(is_ready, "Alertmanager to be ready")
                for index, case in enumerate(CASES):
                    run_case(index, case)
            except BaseException:
                lines = log_path.read_text().splitlines()
                print("\n".join(lines[-50:]), file=sys.stderr)
                raise
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=STOP_TIMEOUT_S)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=STOP_TIMEOUT_S)


if __name__ == "__main__":
    main()
