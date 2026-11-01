"""Run inside greetd's user/greeter children to inspect their real context."""

import json
import os
import signal
import subprocess
import sys
from pathlib import Path
from typing import NotRequired, TypedDict

import dbus
import dbus.bus


class Probe(TypedDict):
    """A probe's JSON result, read by the test script."""

    uid: int
    pid: int
    read_denied: bool
    search_denied: bool
    password_absent_from_env: bool
    # Login keyring state, session probes only. `secret` only if unlocked.
    unlocked: NotRequired[bool]
    secret: NotRequired[str]


def keyring_state() -> Probe:
    """Even knowing root's key serial must not grant access after PAM."""
    serial = Path("/run/login-test/cache-id").read_text().strip()
    read = subprocess.run(
        ["keyctl", "pipe", serial], capture_output=True, check=False
    )
    search = subprocess.run(
        ["keyctl", "search", "@s", "user", "cryptsetup"],
        capture_output=True,
        check=False,
    )
    return {
        "uid": os.getuid(),
        "pid": os.getpid(),
        "read_denied": read.returncode != 0
        and b"Permission denied" in read.stderr,
        "search_denied": search.returncode != 0,
        "password_absent_from_env": all(
            "test-luks-password" not in value for value in os.environ.values()
        ),
    }


def login_secret(result: Probe) -> None:
    """Inspect the collection without unlocking it or showing a prompt.
    Adds its state to `result`."""
    address = f"unix:path={os.environ['XDG_RUNTIME_DIR']}/bus"
    bus = dbus.bus.BusConnection(address)
    collection = bus.get_object(
        "org.freedesktop.secrets", "/org/freedesktop/secrets/aliases/default"
    )
    properties = dbus.Interface(collection, "org.freedesktop.DBus.Properties")
    locked = bool(properties.Get("org.freedesktop.Secret.Collection", "Locked"))
    result["unlocked"] = not locked
    if not locked:
        service = dbus.Interface(
            bus.get_object(
                "org.freedesktop.secrets", "/org/freedesktop/secrets"
            ),
            "org.freedesktop.Secret.Service",
        )
        _, session_path = service.OpenSession("plain", dbus.String(""))
        unlocked, locked_items = service.SearchItems({"test": "desktop-login"})
        assert len(unlocked) == 1 and not locked_items
        item = dbus.Interface(
            bus.get_object("org.freedesktop.secrets", unlocked[0]),
            "org.freedesktop.Secret.Item",
        )
        result["secret"] = bytes(item.GetSecret(session_path)[2]).decode()


def main() -> None:
    """Publish results atomically, then keep the fake desktop session alive."""
    mode = sys.argv[1]
    result = keyring_state()
    if mode == "greeter":
        path = Path("/run/login-test/greeter/probe.json")
    else:
        path = Path.home() / f"{mode}.json"
    if mode == "session":
        login_secret(result)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(result))
    temporary.replace(path)
    if mode == "greeter":
        os.execv(sys.argv[2], sys.argv[2:])
    if mode == "session":
        signal.pause()


if __name__ == "__main__":
    main()
