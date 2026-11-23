#!/usr/bin/env python3
"""Prune unused workspaces, dev/test/lint tools, mobile-native packages, and
non-linux-x64 optional binaries from Paseo's package.json and package-lock.json.

Runs on the copied source tree before `fetchNpmDeps` and `npm ci`, shrinking
the npm cache FOD from ~3.3 GiB to ~200 MiB and `node_modules` from ~4.1 GiB
to ~950 MiB without requiring fragile patches against `package-lock.json`.
"""

import json
import shutil
import sys
from pathlib import Path
from typing import Any

# Workspaces never built or loaded by the NixOS daemon, CLI, or web UI.
DROP_WORKSPACES: set[str] = {
    "packages/website",
    "packages/desktop",
}

# Dev/test/lint/CI/deploy tools unused during Nix production builds.
# Keep expo-gradle-jvmargs (referenced by packages/app/app.config.js plugins).
DROP_DEV_DEPS: set[str] = {
    "@playwright/test",
    "@testing-library/dom",
    "@testing-library/react",
    "@testing-library/react-native",
    "@types/jest",
    "@vitest/browser",
    "@vitest/browser-playwright",
    "@vitest/ui",
    "concurrently",
    "cross-env",
    "eas-cli",
    "electron",
    "electron-builder",
    "eslint",
    "eslint-config-expo",
    "expo-module-scripts",
    "fake-indexeddb",
    "get-port-cli",
    "js-yaml",
    "jsdom",
    "knip",
    "lefthook",
    "material-icon-theme",
    "oxfmt",
    "oxlint",
    "oxlint-tsgolint",
    "playwright",
    "serve-sim",
    "tsx",
    "vitest",
    "wrangler",
    "zx",
}

# Workspace runtime deps unused on NixOS:
# - packages/app: mobile-native-only or offline-codegen deps unused by web UI.
# - packages/server: local speech runtime (disabled in server.postPatch;
#   sherpa-onnx-node-loader.ts requires it lazily).
DROP_WORKSPACE_DEPS: dict[str, set[str]] = {
    "packages/app": {
        "@shopify/react-native-skia",
        "expo-image",
        "expo-image-manipulator",
        "expo-sqlite",
        "mermaid",
    },
    "packages/server": {
        "sherpa-onnx-node",
    },
}

# Optional native binary packages unused at both build time and runtime
# (Paseo invokes the host-managed `claude` binary, never the SDK's embedded one).
DROP_OPT_PREFIXES: tuple[str, ...] = ("@anthropic-ai/claude-agent-sdk-",)

# Transitive mobile/dev-only packages pulled in by react-native and
# @react-native/dev-middleware that are never loaded during a production web
# export on glibc Linux. Note: intentionally severs their prod edges in
# package-lock.json (`npm ci` installs cleanly without them).
DROP_TRANSITIVE_DEPS: set[str] = {
    "@react-native/debugger-frontend",
    "@react-native/debugger-shell",
    "fb-dotslash",
    "hermes-compiler",
    "react-devtools-core",
}


def should_drop_dep(dep_name: str) -> bool:
    """Return True if a transitive/optional dependency name should be pruned."""
    return (
        dep_name in DROP_TRANSITIVE_DEPS
        or "-musl" in dep_name
        or dep_name.startswith(DROP_OPT_PREFIXES)
    )


def platform_matches(meta: dict[str, Any]) -> bool:
    """Return True if os/cpu/libc constraints match x86_64-linux glibc."""
    for field, target in (
        ("os", "linux"),
        ("cpu", "x64"),
        ("libc", "glibc"),
    ):
        raw_values = meta.get(field)
        if isinstance(raw_values, str):
            values = [raw_values]
        elif isinstance(raw_values, list):
            values = [val for val in raw_values if isinstance(val, str)]
        else:
            continue
        if not values:
            continue
        allowed = [val for val in values if not val.startswith("!")]
        denied = [val[1:] for val in values if val.startswith("!")]
        if allowed and "any" not in allowed and target not in allowed:
            return False
        if target in denied:
            return False
    return True


def resolve_dep(
    pkgs: dict[str, dict[str, Any]], importer_key: str, dep_name: str
) -> str | None:
    """Resolve `dep_name` from `importer_key` using npm's node_modules walk."""
    prefix = importer_key
    while True:
        candidate = (
            f"{prefix}/node_modules/{dep_name}"
            if prefix
            else f"node_modules/{dep_name}"
        )
        if candidate in pkgs:
            return candidate
        if not prefix:
            return None
        if "/node_modules/" in prefix:
            prefix = prefix.rsplit("/node_modules/", 1)[0]
        else:
            prefix = ""


def prune_workspace_manifest(ws_key: str, manifest: dict[str, Any]) -> bool:
    """Drop pruned workspaces and dev/runtime deps from a workspace manifest."""
    changed = False
    if ws_key == "" and isinstance(manifest.get("workspaces"), list):
        filtered_ws = [
            ws for ws in manifest["workspaces"] if ws not in DROP_WORKSPACES
        ]
        if len(filtered_ws) != len(manifest["workspaces"]):
            manifest["workspaces"] = filtered_ws
            changed = True

    dev_deps = manifest.get("devDependencies")
    if isinstance(dev_deps, dict):
        filtered_dev = {
            name: spec
            for name, spec in dev_deps.items()
            if name not in DROP_DEV_DEPS
        }
        if len(filtered_dev) != len(dev_deps):
            manifest["devDependencies"] = filtered_dev
            changed = True

    drop_deps = DROP_WORKSPACE_DEPS.get(ws_key)
    runtime_deps = manifest.get("dependencies")
    if drop_deps and isinstance(runtime_deps, dict):
        filtered_deps = {
            name: spec
            for name, spec in runtime_deps.items()
            if name not in drop_deps
        }
        if len(filtered_deps) != len(runtime_deps):
            manifest["dependencies"] = filtered_deps
            changed = True

    return changed


def write_json(path: Path, data: dict[str, Any]) -> None:
    """Serialize JSON with 2-space indentation matching npm's lockfile format."""
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def prune(root: Path) -> None:
    """Prune workspace manifests and reachability-GC package-lock.json."""
    # 1. Remove dropped workspace directories.
    for ws in DROP_WORKSPACES:
        ws_dir = root / ws
        if ws_dir.exists():
            shutil.rmtree(ws_dir)

    # 2. Prune root and remaining workspace package.json files.
    root_pkg_path = root / "package.json"
    root_pkg: dict[str, Any] = json.loads(root_pkg_path.read_text("utf-8"))
    prune_workspace_manifest("", root_pkg)
    write_json(root_pkg_path, root_pkg)

    for ws in root_pkg.get("workspaces", []):
        ws_pkg_path = root / ws / "package.json"
        if not ws_pkg_path.is_file():
            continue
        ws_pkg: dict[str, Any] = json.loads(ws_pkg_path.read_text("utf-8"))
        if prune_workspace_manifest(ws, ws_pkg):
            write_json(ws_pkg_path, ws_pkg)

    # 3. Sync workspace entries in package-lock.json and run reachability GC.
    lock_path = root / "package-lock.json"
    lock: dict[str, Any] = json.loads(lock_path.read_text("utf-8"))
    pkgs: dict[str, dict[str, Any]] = lock["packages"]

    for ws in DROP_WORKSPACES:
        pkgs.pop(ws, None)

    for key, meta in pkgs.items():
        if "node_modules" not in key:
            prune_workspace_manifest(key, meta)

    # Keep every remaining workspace entry AND its `node_modules/<name>` symlink
    # entry (npm ci expects link entries even for leaf workspaces like app/cli).
    kept_workspaces = {key for key in pkgs if "node_modules" not in key}
    roots = list(kept_workspaces)
    for key, meta in pkgs.items():
        if meta.get("link") and meta.get("resolved") in kept_workspaces:
            roots.append(key)

    reachable: set[str] = set(roots)
    queue: list[str] = list(kept_workspaces)

    while queue:
        cur = queue.pop()
        meta = pkgs[cur]
        is_ws = "node_modules" not in cur
        dep_fields = ("dependencies", "optionalDependencies", "peerDependencies")
        if is_ws:
            dep_fields = (*dep_fields, "devDependencies")

        for field in dep_fields:
            deps = meta.get(field)
            if not isinstance(deps, dict):
                continue
            for dep_name in deps:
                if should_drop_dep(dep_name):
                    continue
                target = resolve_dep(pkgs, cur, dep_name)
                if target is None or target in reachable:
                    continue
                target_meta = pkgs[target]
                if target_meta.get("link"):
                    resolved = target_meta.get("resolved")
                    if resolved in DROP_WORKSPACES:
                        continue
                    reachable.add(target)
                    if (
                        isinstance(resolved, str)
                        and resolved in pkgs
                        and resolved not in reachable
                    ):
                        reachable.add(resolved)
                        queue.append(resolved)
                    continue
                if not platform_matches(target_meta):
                    continue
                reachable.add(target)
                queue.append(target)

    # Drop pruned optional deps from kept packages' optionalDependencies maps
    # so `npm ci` does not complain about missing lockfile entries.
    kept_pkgs: dict[str, dict[str, Any]] = {}
    for key in sorted(reachable):
        meta = pkgs[key]
        opt_deps = meta.get("optionalDependencies")
        if isinstance(opt_deps, dict):
            meta["optionalDependencies"] = {
                dep_name: spec
                for dep_name, spec in opt_deps.items()
                if not should_drop_dep(dep_name)
                and (target := resolve_dep(pkgs, key, dep_name)) is not None
                and target in reachable
            }
        kept_pkgs[key] = meta

    orig_count = len(pkgs)
    lock["packages"] = kept_pkgs
    write_json(lock_path, lock)
    print(f"prune-lockfile: {orig_count} -> {len(kept_pkgs)} lockfile entries")


if __name__ == "__main__":
    target_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    prune(target_dir)
