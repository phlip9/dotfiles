"""Drive the real Grafana UI w/ headless Firefox, for agents.

commands (installed as `grafana-<command>` wrappers):
- screenshot: PNG of a dashboard or panel, so agents can see what they
  built. No Grafana image renderer needed.
- resave: save a Scratch copy through the UI, like a user clicking Save. The
  UI fills in its panel defaults, so promoting the copy doesn't leave a big
  noise diff for the user's first UI save.

Auth is an `Authorization` header on requests to Grafana's origin only
(see `new_context`), so it works w/ the same service account token as
mcp-grafana.

env:
- GRAFANA_URL: default https://grafana.phlip9.com
- GRAFANA_USER + GRAFANA_PASSWORD: basic auth, if both set
- GRAFANA_TOKEN_FILE: else, service account token file. Default:
  ~/.config/grafana/mcp-sa-token
"""

import argparse
import asyncio
import base64
import json
import os
import re
import sys
import time
from urllib.parse import urlencode, urlsplit

from playwright.async_api import TimeoutError as PlaywrightTimeout
from playwright.async_api import async_playwright

# Grafana's kiosk footer is `position: fixed`; hide it so it doesn't cover
# panels in full-page shots.
HIDE_CSS = '[data-testid="public-dashboard-footer"] { display: none !important; }'

# Page texts that mean the page is useless.
FATAL_TEXTS = {
    "Grafana has failed to load its application files": "Grafana didn't boot",
    "Panel not found": "no such --panel id",
    "Dashboard not found": "no such dashboard",
}

# Row headers in v2 RowsLayout dashboards, and the collapsed ones.
ROW_TOGGLES = '[data-testid^="data-testid dashboard-row-toggle-for-"]'
COLLAPSED_ROWS = f'{ROW_TOGGLES}[aria-expanded="false"]'

# Edit mode toggle, its Save button, and the Save drawer's confirm button.
EDIT_BUTTON = "data-testid Edit dashboard button"
SAVE_BUTTON = "data-testid Save dashboard button"
SAVE_DRAWER_BUTTON = "data-testid Save dashboard drawer button"

# Dashboards k8s API (v2 schema), relative to GRAFANA_URL.
DASH_API = "/apis/dashboard.grafana.app/v2/namespaces/default/dashboards"


def grafana_url():
    return os.environ.get("GRAFANA_URL", "https://grafana.phlip9.com").rstrip(
        "/"
    )


def auth_header():
    """`Authorization` header value from env, like just/grafana-*.sh."""
    user = os.environ.get("GRAFANA_USER")
    password = os.environ.get("GRAFANA_PASSWORD")
    if user and password:
        cred = base64.b64encode(f"{user}:{password}".encode()).decode()
        return f"Basic {cred}"
    path = os.environ.get(
        "GRAFANA_TOKEN_FILE",
        os.path.expanduser("~/.config/grafana/mcp-sa-token"),
    )
    try:
        with open(path) as f:
            return f"Bearer {f.read().strip()}"
    except OSError as err:
        sys.exit(
            f"error: no Grafana credentials: {err}; "
            "set GRAFANA_TOKEN_FILE or GRAFANA_USER/GRAFANA_PASSWORD"
        )


def ensure_fontconfig():
    """Use the wrapper's fallback fontconfig on hosts w/o a system one.

    Headless Linux hosts w/o /etc/fonts make the browser abort or render
    tofu. Hosts w/ a fontconfig keep their own fonts.
    """
    fallback = os.environ.get("GRAFANA_SCREENSHOT_FONTCONFIG_FILE")
    if not fallback or "FONTCONFIG_FILE" in os.environ:
        return
    if not os.path.exists("/etc/fonts/fonts.conf"):
        os.environ["FONTCONFIG_FILE"] = fallback


class QueryTracker:
    """Tracks in-flight panel data requests to tell when panels finished."""

    def __init__(self, page):
        self.pending = set()
        self.failed = []
        page.on("request", self._start)
        page.on("requestfinished", self._finish)
        page.on("requestfailed", self._fail)

    @staticmethod
    def _is_query(req):
        return "/api/ds/query" in req.url

    def _start(self, req):
        if self._is_query(req):
            self.pending.add(req)

    def _finish(self, req):
        self.pending.discard(req)

    def _fail(self, req):
        if req in self.pending:
            self.failed.append(f"{req.url}: {req.failure}")
        self.pending.discard(req)

    async def idle(self, timeout, quiet=1.0):
        """Wait until no query was in flight for `quiet` seconds."""
        # Give lazy panels a moment to start their queries.
        await asyncio.sleep(0.5)
        deadline = time.monotonic() + timeout
        quiet_since = time.monotonic()
        while time.monotonic() < deadline:
            if self.pending:
                quiet_since = time.monotonic()
            elif time.monotonic() - quiet_since >= quiet:
                return
            await asyncio.sleep(0.1)
        print(
            f"warning: {len(self.pending)} queries still pending",
            file=sys.stderr,
        )


async def new_context(browser, width, height, theme="dark"):
    """Browser context that authenticates its requests to Grafana."""
    context = await browser.new_context(
        viewport={"width": width, "height": height},
        color_scheme=theme,
        # Headless Firefox w/o a system locale gets an empty
        # `navigator.language`, so Grafana's bootstrap (uPlot's
        # `new Intl.NumberFormat(navigator.language)`) throws.
        locale="en-US",
    )

    # Credentials only go to Grafana's origin, never to 3rd-party hosts (ex:
    # an external image in a text panel). Header overrides would follow
    # redirects, so fetch w/o following them and let the browser follow
    # each hop as a new request: only Grafana-origin hops get auth.
    auth = auth_header()

    async def add_auth(route):
        headers = {**route.request.headers, "authorization": auth}
        resp = await route.fetch(headers=headers, max_redirects=0)
        await route.fulfill(response=resp)

    await context.route(f"{grafana_url()}/**", add_auth)
    return context


async def api_get(context, path):
    """Authenticated GET of Grafana API `path` (bypasses page routes).
    Doesn't follow redirects, which would carry the credentials along."""
    return await context.request.get(
        f"{grafana_url()}{path}",
        headers={"Authorization": auth_header()},
        max_redirects=0,
    )


async def load(page, tracker, url, timeout):
    """Open `url`, wait for its panel queries, and fail on error pages."""
    resp = await page.goto(url, wait_until="load", timeout=timeout * 1000)
    if resp is None or not resp.ok:
        status = resp.status if resp else "no response"
        sys.exit(f"error: GET {url}: {status}")
    await tracker.idle(timeout)
    for text, reason in FATAL_TEXTS.items():
        if await page.get_by_text(text).count() > 0:
            sys.exit(f"error: {reason}: page shows {text!r}: {url}")


async def expand_rows(page, tracker, timeout):
    """Expand all collapsed rows, incl. nested ones revealed by expanding.
    Returns the expanded rows' toggle test ids, outermost first."""
    expanded = []
    # Expanding a row shifts the others; re-query each time.
    rows = page.locator(COLLAPSED_ROWS)
    while await rows.count() > 0:
        toggle = rows.first
        expanded.append(await toggle.get_attribute("data-testid"))
        await toggle.click()
        await page.wait_for_timeout(200)
    await tracker.idle(timeout)
    return expanded


# --- screenshot --- #


def screenshot_args(p):
    p.description = "Screenshot a Grafana dashboard (or one panel) to PNG."
    p.add_argument("uid", help="dashboard uid, ex: scratch-nginx")
    p.add_argument("-o", "--out", help="output PNG (default: <uid>.png)")
    p.add_argument("--from", dest="time_from", default="now-24h")
    p.add_argument("--to", dest="time_to", default="now")
    p.add_argument(
        "--panel",
        type=int,
        help="only this panel, by numeric panel id (v2: element .spec.id)",
    )
    p.add_argument(
        "--expand", action="store_true", help="expand all collapsed rows"
    )
    p.add_argument("--width", type=int, default=1600)
    p.add_argument(
        "--height",
        type=int,
        help="viewport + image height (default: full dashboard, or 900 w/ "
        "--panel)",
    )
    p.add_argument("--theme", choices=["dark", "light"], default="dark")
    p.add_argument(
        "--var",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="dashboard variable, repeatable",
    )
    p.add_argument(
        "--timeout", type=float, default=60, help="max seconds per wait"
    )


def screenshot_url(args):
    params = [
        ("from", args.time_from),
        ("to", args.time_to),
        ("theme", args.theme),
    ]
    if args.panel is not None:
        params.append(("viewPanel", f"panel-{args.panel}"))
    for var in args.var:
        name, sep, value = var.partition("=")
        if not sep:
            sys.exit(f"error: --var {var!r}: want NAME=VALUE")
        params.append((f"var-{name}", value))
    # Bare `kiosk` hides the app chrome; `kiosk=` doesn't.
    query = f"{urlencode(params)}&kiosk"
    return f"{grafana_url()}/d/{args.uid}?{query}"


async def screenshot(args):
    out = args.out or f"{args.uid}.png"
    url = screenshot_url(args)
    async with async_playwright() as pw:
        browser = await pw.firefox.launch()
        try:
            context = await new_context(
                browser, args.width, args.height or 900, args.theme
            )
            page = await context.new_page()
            tracker = QueryTracker(page)
            await load(page, tracker, url, args.timeout)
            await page.add_style_tag(content=HIDE_CSS)

            if args.expand:
                await expand_rows(page, tracker, args.timeout)

            # Grow the viewport to the whole dashboard, so every panel
            # renders (Grafana lazy-loads off-screen panels).
            if args.panel is None and args.height is None:
                full = await page.evaluate(
                    "() => document.documentElement.scrollHeight"
                )
                await page.set_viewport_size(
                    {"width": args.width, "height": max(full, 600)}
                )
                await tracker.idle(args.timeout)

            # Let the last frames paint.
            await page.evaluate("() => window.scrollTo(0, 0)")
            await page.wait_for_timeout(500)
            # A fixed --height shoots only the viewport: panels below it
            # never loaded (lazy), so a full-page shot would show them blank.
            await page.screenshot(path=out, full_page=args.height is None)
        finally:
            await browser.close()

    for failure in tracker.failed:
        print(f"warning: query failed: {failure}", file=sys.stderr)
    print(f"wrote {out} ({url})")


# --- resave --- #


def resave_args(p):
    p.description = (
        "Save a Scratch copy through the Grafana UI (fills in panel "
        "defaults), like a user clicking Save. Only `scratch-*` uids in "
        "the Scratch folder."
    )
    p.add_argument("uid", help="Scratch copy uid, ex: scratch-nginx")
    p.add_argument(
        "--timeout", type=float, default=60, help="max seconds per wait"
    )


def is_unmanaged_scratch(metadata, uid):
    """Whether dashboard `metadata` is copy `uid` in the Scratch folder,
    not managed by Git Sync: saving it can't commit to `master`."""
    annotations = metadata.get("annotations") or {}
    return all([
        metadata.get("name") == uid,
        annotations.get("grafana.app/folder") == "scratch",
        "grafana.app/managedBy" not in annotations,
    ])


async def check_scratch(context, uid):
    """Exit early (w/ a clear error) unless `uid` is an unmanaged Scratch
    copy. `WriteGuard` enforces it on the save itself."""
    if not uid.startswith("scratch-"):
        sys.exit(f"error: uid {uid} has no scratch- prefix")
    resp = await api_get(context, f"{DASH_API}/{uid}")
    if not resp.ok:
        sys.exit(f"error: GET dashboard {uid}: HTTP {resp.status}")
    if not is_unmanaged_scratch((await resp.json())["metadata"], uid):
        sys.exit(
            f"error: dashboard {uid} is outside the scratch folder or "
            "managed by Git Sync; refusing to save it"
        )


class WriteGuard:
    """Page route that only lets through the writes a resave needs (an
    allowlist): panel queries, feature flag evaluation, and the save of
    the unmanaged Scratch copy `uid`, judged by the request body. Aborts
    the rest, ex: Git Sync (provisioning) saves, other dashboards, or the
    copy after a move out of Scratch since `check_scratch`."""

    # Paths of read-only POSTs, relative to GRAFANA_URL.
    READ_POSTS = (
        re.compile(r"/api/ds/query"),
        re.compile(r"/apis/features\.grafana\.app/[^/]+/namespaces/[^/]+"
                   r"/ofrep/v1/evaluate/flags(/.*)?"),
    )

    def __init__(self, uid):
        self.uid = uid
        self.save_path = re.compile(
            r"/apis/dashboard\.grafana\.app/[^/]+/namespaces/[^/]+"
            rf"/dashboards/{re.escape(uid)}"
        )
        self.blocked = []

    def reason(self, req):
        """Why `req` must not be sent, or None."""
        if req.method in ("GET", "HEAD", "OPTIONS"):
            return None
        # Path relative to GRAFANA_URL, which may have a base path.
        base = urlsplit(grafana_url()).path.rstrip("/")
        path = urlsplit(req.url).path
        if not path.startswith(f"{base}/"):
            return "outside GRAFANA_URL"
        path = path[len(base):]
        if req.method == "POST" and any(
            pattern.fullmatch(path) for pattern in self.READ_POSTS
        ):
            return None
        if req.method != "PUT" or not self.save_path.fullmatch(path):
            return "not an allowed write"
        try:
            metadata = json.loads(req.post_data or "")["metadata"]
        except (ValueError, KeyError, TypeError):
            return "unreadable body"
        if not is_unmanaged_scratch(metadata, self.uid):
            return "body isn't the unmanaged Scratch copy"
        return None

    async def handle(self, route):
        reason = self.reason(route.request)
        if reason is None:
            # On to the context's auth route.
            await route.fallback()
            return
        self.blocked.append(
            f"{route.request.method} {route.request.url}: {reason}"
        )
        await route.abort()


async def resave(args):
    url = f"{grafana_url()}/d/{args.uid}"
    async with async_playwright() as pw:
        browser = await pw.firefox.launch()
        try:
            context = await new_context(browser, 1600, 1000)
            await check_scratch(context, args.uid)
            page = await context.new_page()
            page.set_default_timeout(args.timeout * 1000)
            guard = WriteGuard(args.uid)
            await page.route(f"{grafana_url()}/**", guard.handle)
            tracker = QueryTracker(page)
            await load(page, tracker, url, args.timeout)

            await page.get_by_test_id(EDIT_BUTTON).click()

            # Grafana doesn't fill in the defaults of panels in collapsed
            # rows: their plugins never load. Expand them, then restore the
            # collapse state, which is part of the saved spec. Innermost
            # rows first.
            expanded = await expand_rows(page, tracker, args.timeout)
            for test_id in reversed(expanded):
                await page.get_by_test_id(test_id).click()
                await page.wait_for_timeout(200)

            await page.get_by_test_id(SAVE_BUTTON).click()
            save = page.get_by_test_id(SAVE_DRAWER_BUTTON)
            await save.wait_for()
            if await save.is_disabled():
                print(f"no changes: {args.uid}")
                return

            # Wait for the save request + its response, within --timeout.
            def is_save(req):
                path = urlsplit(req.url).path
                return req.method == "PUT" and path.endswith(
                    f"/dashboards/{args.uid}"
                )

            async def click_save():
                async with page.expect_request(is_save) as req_info:
                    await save.click()
                return await (await req_info.value).response()

            try:
                resp = await asyncio.wait_for(click_save(), args.timeout)
            except (PlaywrightTimeout, asyncio.TimeoutError):
                resp = None
            for blocked in guard.blocked:
                print(f"warning: blocked: {blocked}", file=sys.stderr)
            if resp is None:
                sys.exit(f"error: save {args.uid}: no response")
            if not resp.ok:
                sys.exit(f"error: save {args.uid}: HTTP {resp.status}")
            # Firefox can't always hand over the save resp's body; re-GET.
            saved = await api_get(context, f"{DASH_API}/{args.uid}")
            if not saved.ok:
                sys.exit(
                    f"error: GET dashboard {args.uid}: HTTP {saved.status}"
                )
            generation = (await saved.json())["metadata"].get("generation")
        finally:
            await browser.close()

    print(f"saved {args.uid} via the UI (generation {generation}): {url}")


# --- main --- #

COMMANDS = {
    "screenshot": (screenshot_args, screenshot),
    "resave": (resave_args, resave),
}


def main():
    # The `grafana-<command>` wrappers pass the command as the first arg.
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(f"usage: grafana-browser {{{','.join(COMMANDS)}}} ...")
    command = sys.argv[1]
    add_args, run = COMMANDS[command]
    parser = argparse.ArgumentParser(prog=f"grafana-{command}")
    add_args(parser)
    args = parser.parse_args(sys.argv[2:])
    ensure_fontconfig()
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
