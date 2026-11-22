"""Shared helpers for NixOS VM and container test scripts.

Injected into every `runNixOSTest` via `extraPythonPackages` in
`nixos/tests/default.nix`, so `ty` and `ruff` check imports at driver build
time and `just python-ci` checks this package on both Linux and macOS.
"""

from collections.abc import Callable, Sequence
import datetime as dt
import json
import shlex
import time
from typing import Protocol, TypeVar

T = TypeVar("T")

# Bound every curl so a hung server fails its step, not globalTimeout, and
# `dump_evidence` still runs.
CURL = "curl -sS --connect-timeout 2 --max-time 10"
# Silent bounded curl for readiness polls (no stderr spam while waiting).
CURL_QUIET = "curl -sf --connect-timeout 2 --max-time 10"
# Upper bound for one guest command, incl. its curl.
CMD_TIMEOUT = dt.timedelta(seconds=15)
# Default upper bound for polling waits.
WAIT_TIMEOUT = dt.timedelta(seconds=30)
# Upper bound for a service to start and become ready.
UP_TIMEOUT = dt.timedelta(seconds=60)


class Machine(Protocol):
    """Structural subset of `test_driver.machine.BaseMachine`.

    Avoids importing `test_driver` so `just python-ci` works on macOS too.
    """

    name: str

    def execute(
        self,
        command: str,
        *,
        timeout: dt.timedelta | None = ...,
    ) -> tuple[int, str]: ...

    def succeed(
        self,
        *commands: str,
        timeout: dt.timedelta | None = ...,
    ) -> str: ...

    def fail(
        self,
        *commands: str,
        timeout: dt.timedelta | None = ...,
    ) -> str: ...


def wait_fast(
    check: Callable[[], object],
    what: str,
    timeout: dt.timedelta = WAIT_TIMEOUT,
) -> None:
    """Poll `check` back to back without `retry`'s 1s sleep.

    Each call should block on a guest command or I/O so this isn't a pure CPU
    busy loop.
    """
    deadline = time.monotonic() + timeout.total_seconds()
    while not check():
        if time.monotonic() > deadline:
            secs = timeout.total_seconds()
            raise TimeoutError(f"timed out after {secs:.0f}s: {what}")


def wait_for_value(
    fn: Callable[[], T | None],
    what: str,
    timeout: dt.timedelta = WAIT_TIMEOUT,
) -> T:
    """Poll `fn` back to back until it returns a truthy value, then return it."""
    deadline = time.monotonic() + timeout.total_seconds()
    while True:
        value = fn()
        if value:
            return value
        if time.monotonic() > deadline:
            secs = timeout.total_seconds()
            raise TimeoutError(f"timed out after {secs:.0f}s: {what}")


def wait_for_cmd(
    node: Machine,
    cmd: str,
    timeout: dt.timedelta = WAIT_TIMEOUT,
    cmd_timeout: dt.timedelta = CMD_TIMEOUT,
) -> str:
    """Fast drop-in for `node.wait_until_succeeds`, without 1s sleeps."""
    deadline = time.monotonic() + timeout.total_seconds()
    last_out = ""
    while True:
        status, last_out = node.execute(cmd, timeout=cmd_timeout)
        if status == 0:
            return last_out
        if time.monotonic() > deadline:
            secs = timeout.total_seconds()
            raise TimeoutError(
                f"timed out after {secs:.0f}s: {node.name}: {cmd}\n{last_out}"
            )


def wait_for_port(
    node: Machine,
    port: int,
    timeout: dt.timedelta = WAIT_TIMEOUT,
) -> None:
    """Fast TCP listen check via `ss -Hltn`, without `wait_for_open_port`'s 1s sleep."""
    wait_for_cmd(
        node,
        f"ss -Hltn 'sport = :{port}' | grep -q :{port}",
        timeout=timeout,
    )


def wait_for_http(
    node: Machine,
    url: str,
    timeout: dt.timedelta = UP_TIMEOUT,
) -> str:
    """Fast HTTP 2xx readiness poll using bounded silent curl."""
    return wait_for_cmd(
        node,
        f"{CURL_QUIET} {shlex.quote(url)}",
        timeout=timeout,
    )


def batch_requests(
    node: Machine,
    reqs: Sequence[tuple[str, str]],
    auth: tuple[str, str] | None = None,
    timeout: dt.timedelta = CMD_TIMEOUT,
) -> list[str]:
    """Run `(url, method)` requests in one `curl -K -` call (reuses HTTP/2 TLS).

    Returns one HTTP status code string per request. Uses `execute` (not
    `succeed`) so large curl configs aren't echoed twice into test logs.
    """
    creds = ":".join(auth) if auth is not None else None
    stanzas: list[str] = []
    for url, method in reqs:
        lines = [
            f"url = {json.dumps(url)}",
            'output = "/dev/null"',
            'write-out = "%{http_code}\\n"',
            "path-as-is",
            "connect-timeout = 2",
            "max-time = 10",
            "head" if method == "HEAD" else f"request = {json.dumps(method)}",
        ]
        if creds is not None:
            lines.append(f"user = {json.dumps(creds)}")
        stanzas.append("\n".join(lines))
    cfg = "\nnext\n".join(stanzas) + "\n"
    rc, out = node.execute(
        f"printf %s {shlex.quote(cfg)} | curl -sS -K -",
        timeout=timeout,
    )
    assert rc == 0, (rc, out)
    statuses = out.splitlines()
    assert len(statuses) == len(reqs), (len(statuses), len(reqs), out)
    return statuses


def dump_evidence(
    targets: Sequence[tuple[Machine, Sequence[str]]],
    cmd_timeout: dt.timedelta = CMD_TIMEOUT,
) -> None:
    """Run diagnostic commands on each node w/ bounded timeout on failure."""
    for node, cmds in targets:
        for cmd in cmds:
            _, out = node.execute(cmd, timeout=cmd_timeout)
            print(f"{node.name}$ {cmd}\n{out}")
