---
name: paseo-upgrade
description: Use to upgrade paseo (package, patches, NixOS module, tests, configs) to the latest release
---

# paseo upgrade

Upgrade the `paseo` npins pin from OLD to NEW (default: latest stable
release) and bring our patches, modules, tests, and configs along. Flow:

1. research -> gate: report blockers / newly exposed surface and STOP
2. patches + package build
3. modules, tests, configs
4. verify, commit, final report w/ follow-up proposals, improve this skill

Paseo is security critical: daemon access == full control of sauna as
phlip9. We run a hardened build w/ non-essential features disabled. Treat
every new listener, transport, auth path, outbound call, or default-on
feature as a finding.

Use cheaper Sonnet subagents for independent research (release notes, security
surface, patch review) to save context. Give them the file pointers below.

## Files

Ours (read before starting; the docs for each piece live in these files):

- `npins/sources.json` `paseo` pin (GitRelease, `pre_releases: false`)
- `nixos/pkgs/paseo/default.nix`: vendored split build
  (`npmDeps -> nodeModules -> shared -> (server || webUi) -> paseo`),
  per-sub-drv patch slicer (`assertAllPatchHunksMatched`), `npmDepsHash`,
  ordered `patches` list (one comment per patch)
- `nixos/pkgs/paseo/prune-lockfile.py`: prunes unused workspaces, dev/test/lint
  tools, mobile-only deps, sherpa-onnx, and non-linux-x64 optional binaries
  before `fetchNpmDeps` and `npm ci`
- `nixos/pkgs/paseo/install-server.mjs`: traces daemon + CLI runtime closure
  w/ `@vercel/nft` and copies into `paseo.server` (keep in sync w/ upstream
  `scripts/trace-daemon.mjs`)
- `nixos/pkgs/paseo/install-web-ui.mjs`: copies Expo web UI export into
  `paseo.webUi` and precompresses `.br` (q=9) / `.gz` concurrently
- `nixos/pkgs/paseo/metro-minify-esbuild.cjs`: esbuild Metro minifier for
  `paseo.webUi`
- `nixos/pkgs/paseo/*.patch`: downstream patches
- `nixos/pkgs/paseo/tests/*.patch`: tests for the same-named patch (nix build
  skips them; import/export scripts handle them)
- `.agents/skills/paseo-dev/`: patch development workflow +
  `scripts/paseo-dev` (isolated worktree, check, baseline, browser e2e),
  reused in Phases 2-3. New or reworked patches follow that skill.
- `nixos/mods/paseo.nix`: extends upstream `nix/module.nix` (imported in
  `nixos/mods/default.nix`); `enforcedSettings` hardening pins, relay
  server, nginx
- `nixos/tests/paseo.nix`: VM test (auth, relay, env, terminals, config
  merge, lifecycle)
- `nixos/sauna/default.nix`: `services.paseo` deployment
- `nixos/pkgs/paseo-relay.nix`: third-party self-hosted relay

Upstream (`~/dev/paseo`, clone `https://github.com/getpaseo/paseo` if
missing), security-relevant paths under `packages/server/src/server/`:

- auth: `session-admission-auth.ts`, `auth.ts` (HTTP bypass list),
  `websocket-server.ts` (`attachExternalSocket`, `attachPluginSocket`,
  `admitPendingHello`), `local-credential.ts`
- env/config: `config-environment.ts` (`DAEMON_SETTING_ENV_KEYS`),
  `config.ts` (`resolveAuthConfig`), `persisted-config.ts` (schema +
  defaults seeded into new `config.json`)
- transports/control planes: `bootstrap.ts` (route mounting, relay, hub
  wiring), `hub/`, `../../../relay/src/` (E2EE handshake)
- plugins: `plugins/builtin/index.ts`, `plugins/managed-source.ts`
- providers: `agent/provider-installation/` (update checks, CLI self-updaters)
- permissions: `authorization/operation-permissions.ts`
- packaging: `nix/`, `scripts/trace-daemon.mjs`,
  `scripts/build-daemon-web-ui.mjs`, `scripts/postinstall-patches.mjs`

## Setup

```bash
pa=~/dev/paseo
jq -r '.pins.paseo.version' npins/sources.json        # OLD, e.g. v0.12.0
git -C "$pa" fetch --tags origin
npins update paseo                                    # latest stable
jq -r '.pins.paseo.version' npins/sources.json        # NEW
just phlippkgs-update paseo-relay                     # relay main HEAD

# patch branch: reuse phlip9/<OLD> if present, else rebuild it from our
# patch files (commit subject == patch file stem)
git -C "$pa" branch --list 'phlip9/*'
.agents/skills/paseo-upgrade/scripts/import-patches.sh "$pa" <OLD> phlip9/<OLD>

art=/tmp/paseo-upgrade-<NEW>; mkdir -p "$art"
```

If the user named a version that differs from the bumped pin, ask first.

## Phase 1: research

Run in parallel subagents:

1. **Release notes**: `CHANGELOG.md` entries OLD..NEW, skim
   `git log --oneline <OLD>..<NEW>`. Breaking changes to things we use:
   env vars, CLI flags (`--no-relay`), CLI commands the test drives,
   `/api/health` + `/api/status` shape, provider config schema.
2. **Packaging**: `git diff <OLD> <NEW> -- nix/ patches/ scripts/trace-daemon.mjs scripts/build-daemon-web-ui.mjs scripts/postinstall-patches.mjs package.json package-lock.json 'packages/*/package.json' plugins/package.json`.
   `nixos/pkgs/paseo/default.nix` is vendored (port upstream build/dep changes
   to `default.nix`, `prune-lockfile.py`, `install-server.mjs`, and
   `install-web-ui.mjs`). `nix/module.nix` is still imported: option/ExecStart/
   preStart changes affect `nixos/mods/paseo.nix` overrides (`mkForce`d
   ExecStart, WorkingDirectory, preStart ordering).
3. **Security surface** (diff OLD vs NEW for each):
   - owner admission paths, i.e. every way to get a session w/o the
     password: `git grep -nE 'OWNER_PERMISSIONS|OWNER_SESSION_ADMISSION|principalId: "owner"' <rev> -- packages/server/src ':!*.test.ts'`
   - listeners/routes: `git grep -nE 'createServer|\.listen\(|app\.(get|post|use)\(' <rev> -- packages/server/src packages/relay/src ':!*test*'`
   - new env keys and persisted config defaults (insecure seeds like the
     old `cors.allowedOrigins = ["https://app.paseo.sh"]` default)
   - `COMPAT(...)` markers in auth/relay files: did upstream finally drop
     a compat path we patch out?
   - new builtin plugins, providers enabled by default, outbound
     `fetch(` targets, new control planes (hub-like features)
   - for each: default on/off, disable knob (env/config) or patch needed
4. **Patch review**: per patch in `nixos/pkgs/paseo/default.nix`, fixed upstream
   (drop), still applies, or needs a rebase? Grep for the patch's
   functions/keys in `<OLD>..<NEW>` history.
   - A clean apply proves nothing for patches that replace a built module
     (`server.buildPhase` `cp ... compiler-build.js` in `default.nix`, e.g.
     `paseo-precompile-plugins`): diff the replaced module's exports and
     importers OLD..NEW. A missing export only fails at daemon startup.
   - `nodeModules.buildPhase` runs `npm run postinstall` explicitly because
     `npmRebuildFlags = [ "--ignore-scripts" ]` skips lifecycle hooks (see
     upstream getpaseo/paseo#7673). Check if upstream changed
     `scripts/postinstall-patches.mjs` or `patches/*.patch`. Your `gh` can't
     read getpaseo repos; use
     `curl -s https://api.github.com/repos/getpaseo/paseo/issues/7673 | jq .state`.

## Gate: report

If anything is breaking, newly exposed (listener, transport, auth bypass,
default-on feature/provider), or needs a decision (new patch vs config
knob): report and STOP. Otherwise continue and report at the end.

## Phase 2: patches + package

```bash
git -C "$pa" switch -c phlip9/<NEW> phlip9/<OLD>
git -C "$pa" rebase --onto <NEW> <OLD>     # resolve conflicts per commit
# drop commits fixed upstream; new patch == new commit w/ subject paseo-<name>
.agents/skills/paseo-upgrade/scripts/export-patches.sh "$pa" <NEW>
```

`export-patches.sh` rewrites `nixos/pkgs/paseo/*.patch` (+ `tests/`) and reports
where the shipped `patches` list (evaluated by `patch-list.sh` via nix, as
import uses) differs from the branch: entries to add/remove, or order.
Keep patches minimal and fail-closed.

npmDepsHash (differs from upstream `nix/npm-deps.hash`: pruned lockfile +
nixpkgs): set `npmDepsHash = lib.fakeHash;`, run `nix build -f . paseo.npmDeps`
(~10s), and copy `got:`. If `npm ci` or a sub-drv fails on a renamed/new
dependency or workspace, update `prune-lockfile.py` or `default.nix`
(`mkScope` declarations, `substituteInPlace` hooks).

```bash
timeout 1200 nix build -f . paseo -o "$art/paseo" > "$art/build.log" 2>&1
grep -E 'error TS|FAILED|^error' "$art/build.log"
"$art/paseo/bin/paseo" --version
```

- Cold build takes ~2.5 min (`server` and `webUi` build in parallel).
  Incremental rebuilds take ~35s for server/cli-only changes (`paseo.server`)
  and ~95s for web UI changes (`paseo.webUi`). Run in the background, one heavy
  build at a time.
- Patched TS must typecheck (`noUnusedLocals`, control-flow narrowing).
  Failures surface during `paseo.shared` or `paseo.server` as `error TS`; fix
  them on the patch branch, then re-export.

## Phase 3: modules, tests, configs

```bash
timeout 900 nix build -f . nixosTests.paseo -L --no-link \
  > "$art/test.log" 2>&1; echo "exit=$?" >> "$art/test.log"
grep -E 'subtest:|!!!|finished: run the VM' "$art/test.log"
grep -iE 'deprecat' "$art/test.log" | grep -v '^paseo>'   # CLI deprecations
grep -E 'Failed to start built-in plugin|"level":(50|60)' "$art/test.log"
```

The container test itself runs ~30s once `paseo` is built.

Patch-level checks once `npins` points at NEW and patches are exported
(`P=.agents/skills/paseo-dev/scripts/paseo-dev`):

```bash
$P reset --force     # fresh tmp/paseo at NEW from nixos/pkgs/paseo
$P check --all       # fmt/lint/typecheck + related tests for every patch
```

- Timing tests flake under load: don't run `check` next to a nix build.
- Failing test: `$P baseline <pkg> <file>` to split upstream failures
  from ours. An upstream test that conflicts w/ a patch goes in
  `nixos/pkgs/paseo/tests/ignored.json` per `paseo-dev` "5. Check"; never weaken
  a patch or edit upstream tests. Stale `ignored.json` entries fail the
  run: drop or retitle them.
- UI patches (`paseo-commit-message`, ...): for each one with a rebase
  conflict or touching changed upstream UI, run a `paseo-dev` "UI visual
  verify" check (`$P visual <slug>`, `$P e2e ...`) on desktop + phone.

- New default-on features/providers/insecure defaults: pin them off in
  `enforcedSettings` (`nixos/mods/paseo.nix`) if a config knob exists,
  else patch.
- New security-relevant patch or pin -> add a VM subtest. Mutation-check
  it: comment out the patch, test must fail, restore. Also do this for
  existing security patches that needed a non-trivial rebase.
- Never weaken the `/api/status` 401 and relay password subtests: if
  `PASEO_PASSWORD_FILE` falls out of `DAEMON_SETTING_ENV_KEYS`, auth is
  silently disabled and only these catch it.
- `paseo-relay` (`nixos/pkgs/paseo-relay.nix`): if upstream
  `packages/relay/src` wire protocol or `MAX_RELAY_WEBSOCKET_MESSAGE_BYTES`
  changed, check the relay supports it (its `maxMessageBytes`).
- On sauna (`hostname`), dry-run the config merge against live state:

  ```bash
  nix eval --json -f . nixosConfigs.sauna.config.services.paseo.enforcedSettings > "$art/enforced.json"
  jq --slurpfile e "$art/enforced.json" '. * $e[0]' ~/.config/paseo/config.json
  ```

## Phase 4: verify + commit

```bash
nix build --dry-run --no-link -f . nixosConfigs.sauna.config.system.build.toplevel
just nix-ci
```

Commits (AGENTS.md conventions; no `Co-Authored-By`):

1. `paseo: <OLD> -> <NEW>` (no `v`): pin, hash, rebased/dropped patches,
   required module/test fixes. Short body listing dropped/rebased patches.
2. New hardening (patch, pin, test) as separate commits after, e.g.
   `paseo: disable <feature>`.

Keep the `phlip9/<NEW>` branch in `~/dev/paseo` (one commit per patch). If
patches were edited or added in `tmp/paseo`, fast-forward/reset `phlip9/<NEW>`
to `tmp/paseo` HEAD before finishing. Don't push, open a PR, or deploy unless
asked.

## Final report

- Release review: blockers, newly exposed surface + how it's disabled.
- Patches: dropped / kept / rebased / new, with evidence.
- Verification: commands + results, mutation checks.
- Post-deploy on sauna: `systemctl status paseo`, journal for plugin
  start errors, re-pair or re-add hosts if auth/pairing changed.
- Follow-up proposals: (1) refactor/simplify packaging or modules, (2) test
  coverage for future upgrades, (3) security posture.

## Improve this skill

After a successful run, update this skill (`SKILL.md`, `scripts/`) in a
separate commit, `ai: paseo-upgrade: <what>`. Fix friction, misses found
late, and drifted paths/commands. Record a gotcha only if it will likely
recur in most upgrades; findings for one release go in the report and
commit messages. Shellcheck scripts manually (`just bash-lint` skips hidden
dirs):

```bash
nix shell -f . pkgs.shellcheck --command \
  shellcheck .agents/skills/paseo-upgrade/scripts/*.sh
```
