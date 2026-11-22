"""Shared o11y helpers (VictoriaMetrics, Pyroscope, Prometheus metrics)."""

from collections.abc import Sequence
import datetime as dt
import json
import shlex
import time
from typing import Any

from . import (
    CMD_TIMEOUT,
    CURL,
    WAIT_TIMEOUT,
    Machine,
    wait_for_value,
)

VM_URL = "http://127.0.0.1:8428"
PYRO_URL = "http://127.0.0.1:4040"
VMAGENT_URL = "http://127.0.0.1:8429"


# --- Prometheus text metrics --- #


def metrics_scrape(
    node: Machine,
    url: str,
    timeout: dt.timedelta = CMD_TIMEOUT,
) -> list[str]:
    """Scrape `{url}/metrics` and return non-comment sample lines."""
    out = node.succeed(f"{CURL} -f {shlex.quote(url)}/metrics", timeout=timeout)
    return [line for line in out.splitlines() if not line.startswith("#")]


def metric_sum(scrape: Sequence[str], name: str, match: str = "") -> float:
    """Sum sample values of metric `name` whose line contains `match`."""
    total = 0.0
    prefixes = (name + "{", name + " ")
    for line in scrape:
        if line.startswith(prefixes) and match in line:
            total += float(line.rsplit(" ", 1)[1])
    return total


# --- VictoriaMetrics --- #


def vm_flush(
    node: Machine,
    url: str = VM_URL,
    timeout: dt.timedelta = CMD_TIMEOUT,
) -> None:
    """Flush VictoriaMetrics' pending raw rows so queries can see them."""
    node.succeed(
        f"{CURL} -f {shlex.quote(url)}/internal/force_flush",
        timeout=timeout,
    )


def vm_query(
    node: Machine,
    promql: str,
    *,
    flush: bool = True,
    url: str = VM_URL,
    timeout: dt.timedelta = CMD_TIMEOUT,
) -> list[dict[str, Any]]:
    """Run an instant PromQL query against VictoriaMetrics."""
    base = shlex.quote(url)
    query = shlex.quote(promql)
    prefix = f"{CURL} -f {base}/internal/force_flush && " if flush else ""
    out = node.succeed(
        prefix + f"{CURL} -f {base}/api/v1/query --data-urlencode query={query}",
        timeout=timeout,
    )
    return json.loads(out)["data"]["result"]


def vm_labels(
    node: Machine,
    promql: str,
    *,
    flush: bool = True,
    url: str = VM_URL,
    timeout: dt.timedelta = CMD_TIMEOUT,
) -> list[dict[str, str]]:
    """Return the label dicts of all series matched by `promql`."""
    return [
        res["metric"]
        for res in vm_query(node, promql, flush=flush, url=url, timeout=timeout)
    ]


def wait_for_vm_labels(
    node: Machine,
    promql: str,
    *,
    flush_each: bool = True,
    url: str = VM_URL,
    timeout: dt.timedelta = WAIT_TIMEOUT,
) -> list[dict[str, str]]:
    """Poll `promql` back to back until it returns at least one series.

    Set `flush_each=False` when writes already returned 2xx before polling:
    flushes once, then waits for VM's ~1s indexdb tick without flush log spam.
    """
    if not flush_each:
        vm_flush(node, url=url)
    return wait_for_value(
        lambda: vm_labels(node, promql, flush=flush_each, url=url),
        promql,
        timeout=timeout,
    )


# --- Pyroscope Connect query API --- #


def pyro_window(
    now_ms: int | None = None,
    *,
    before_ms: int = 3_600_000,
    after_ms: int = 3_600_000,
) -> dict[str, int]:
    """Query window `[now - before_ms, now + after_ms]` in epoch ms."""
    center = int(time.time() * 1000) if now_ms is None else now_ms
    return {"start": center - before_ms, "end": center + after_ms}


def pyro_post(
    node: Machine,
    method: str,
    body: dict[str, Any],
    *,
    url: str = PYRO_URL,
    window: dict[str, int] | None = None,
    retry_timeout: dt.timedelta | None = None,
    cmd_timeout: dt.timedelta = CMD_TIMEOUT,
) -> dict[str, Any]:
    """POST JSON to Pyroscope's `QuerierService/{method}`.

    If `retry_timeout` is set, retries transport errors, 5xx, 408, and 429
    until the deadline while failing immediately on other 4xx responses.
    """
    payload = {**(pyro_window() if window is None else window), **body}
    data = shlex.quote(json.dumps(payload))
    endpoint = shlex.quote(f"{url}/querier.v1.QuerierService/{method}")
    if retry_timeout is None:
        out = node.succeed(
            f"{CURL} -f -H 'Content-Type: application/json' "
            f"--data-binary {data} {endpoint}",
            timeout=cmd_timeout,
        )
        resp = json.loads(out)
        assert isinstance(resp, dict), out
        return resp

    cmd = (
        f"{CURL} -w '\\n%{{http_code}}' "
        f"-H 'Content-Type: application/json' --data-binary {data} {endpoint}"
    )
    deadline = time.monotonic() + retry_timeout.total_seconds()
    while True:
        status, out = node.execute(cmd, timeout=cmd_timeout)
        body_out, _, code = out.rpartition("\n")
        if status == 0 and code.startswith("2"):
            resp = json.loads(body_out)
            assert isinstance(resp, dict), out
            return resp
        print(f"Pyroscope {method}: exit {status}, HTTP {code}: {body_out}")
        # 408 + 429 are transient; other 4xx won't recover
        permanent = code.startswith("4") and code not in ("408", "429")
        if status == 0 and permanent:
            raise RuntimeError(f"Pyroscope {method}: HTTP {code}: {body_out}")
        if time.monotonic() > deadline:
            secs = retry_timeout.total_seconds()
            raise TimeoutError(f"Pyroscope {method}: failed for {secs:.0f}s")


def pyro_fn_names(
    node: Machine,
    ptype: str,
    selector: str,
    *,
    url: str = PYRO_URL,
    start_ms: int | None = None,
    end_ms: int | None = None,
    window: dict[str, int] | None = None,
    retry_timeout: dt.timedelta | None = None,
) -> set[str]:
    """Function names in the merged flamegraph, excluding the root `total`."""
    body: dict[str, Any] = {"profileTypeID": ptype, "labelSelector": selector}
    if start_ms is not None:
        body["start"] = start_ms
    if end_ms is not None:
        body["end"] = end_ms
    resp = pyro_post(
        node,
        "SelectMergeStacktraces",
        body,
        url=url,
        window=window,
        retry_timeout=retry_timeout,
    )
    return set(resp.get("flamegraph", {}).get("names", [])) - {"total"}


def pyro_label_values(
    node: Machine,
    label: str,
    *,
    selector: str | None = None,
    url: str = PYRO_URL,
    window: dict[str, int] | None = None,
    retry_timeout: dt.timedelta | None = None,
) -> list[str]:
    """Return `LabelValues` names for `label`, optionally filtered by `selector`."""
    body: dict[str, Any] = {"name": label}
    if selector is not None:
        body["matchers"] = [selector]
    resp = pyro_post(
        node,
        "LabelValues",
        body,
        url=url,
        window=window,
        retry_timeout=retry_timeout,
    )
    return resp.get("names", [])
