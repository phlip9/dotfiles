---
name: paseo-upgrade
description: Use to upgrade paseo (package, patches, NixOS/home-manager modules, tests, configs) to the latest release
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

Use subagents for independent research (release notes, security surface,
patch review) to save context. Give them the file pointers below.

## Files

Ours (read before starting; the docs for each piece live in these files):

- `npins/sources.json` `paseo` pin (GitRelease, `pre_releases: false`)
- `pkgs/paseo/default.nix`: wraps upstream `nix/package.nix`, our
  `npmDepsHash`, ordered `patches` list (one comment per patch), PATH fixup
- `pkgs/paseo/*.patch`: downstream patches
- `nixos/mods/paseo.nix`: extends upstream `nix/module.nix` (imported in
  `nixos/mods/default.nix`); `enforcedSettings` hardening pins, relay
  server, nginx
- `nixos/tests/paseo.nix`: VM test (auth, relay, env, terminals, config
  merge, lifecycle)
- `home/mods/paseo.nix`: home-manager daemon (`phliptop-mbp`, `lexe-dev`)
- `nixos/sauna/default.nix`: `services.paseo` deployment
- `nixos/pkgs/paseo-relay.nix`: third-party self-hosted relay (separate
  upstream, not bumped by this pin)

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
- permissions: `authorization/operation-permissions.ts`
- packaging: `nix/`, `scripts/trace-daemon.mjs`

## Setup

```bash
pa=~/dev/paseo
jq -r '.pins.paseo.version' npins/sources.json        # OLD, e.g. v0.12.0
git -C "$pa" fetch --tags origin
npins update paseo                                     # latest stable
jq -r '.pins.paseo.version' npins/sources.json        # NEW

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
2. **Packaging**: `git diff <OLD> <NEW> -- nix/ scripts/trace-daemon.mjs`.
   Module option/ExecStart/preStart changes affect `nixos/mods/paseo.nix`
   overrides (`mkForce`d ExecStart, WorkingDirectory, preStart ordering).
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
4. **Patch review**: per patch in `pkgs/paseo/default.nix`, fixed upstream
   (drop), still applies, or needs a rebase? Grep for the patch's
   functions/keys in `<OLD>..<NEW>` history.
   - TEMPORARY: our `preBuild = "npm run postinstall"` works around
     getpaseo/paseo#7673 (upstream skips `patches/*.patch`). Drop it if
     the issue is closed or upstream `nix/package.nix` now runs
     `postinstall`/`patch-package`; double-applying fails the build. Remove
     this note once the workaround is gone.

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

`export-patches.sh` rewrites `pkgs/paseo/*.patch` and prints default.nix
entries to add/remove. Keep patches minimal and fail-closed.

npmDepsHash (differs from upstream `nix/npm-deps.hash`, different nixpkgs):
set `npmDepsHash = "";` then `nix build -f . paseo.npmDeps` and copy `got:`.

```bash
timeout 1200 nix build -f . paseo -o "$art/paseo" > "$art/build.log" 2>&1
grep -E 'error TS|FAILED|^error' "$art/build.log"
"$art/paseo/bin/paseo" --version
```

- The package build takes 5-10 min (tsc + Expo web UI bundle), and longer
  when builds run concurrently. Run it in the background, one at a time.
- Patched TS must typecheck (`noUnusedLocals`, control-flow narrowing).
  Failures surface only minutes into the build as `error TS`; fix them on
  the patch branch, then re-export.

## Phase 3: modules, tests, configs

```bash
timeout 900 nix build -f . nixosTests.paseo -L --no-link \
  > "$art/test.log" 2>&1; echo "exit=$?" >> "$art/test.log"
grep -E 'subtest:|!!!|finished: run the VM' "$art/test.log"
grep -iE 'deprecat' "$art/test.log" | grep -v '^paseo>'   # CLI deprecations
grep -E 'Failed to start built-in plugin|"level":(50|60)' "$art/test.log"
```

The VM test itself runs ~1 min; package rebuilds dominate.

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
  `packages/relay/src` wire protocol changed, check its upstream for a
  compatible release; the test asserts its version string.
- On sauna (`hostname`), dry-run the config merge against live state:

  ```bash
  nix eval --json -f . nixosConfigs.sauna.config.services.paseo.enforcedSettings > "$art/enforced.json"
  jq --slurpfile e "$art/enforced.json" '. * $e[0]' ~/.config/paseo/config.json
  ```

## Phase 4: verify + commit

```bash
nix build --no-link -f . homeConfigs.lexe-dev.activationPackage
nix eval --raw -f . homeConfigs.phliptop-mbp.activationPackage.drvPath
nix build --dry-run --no-link -f . nixosConfigs.sauna.config.system.build.toplevel
just nix-ci
```

Commits (AGENTS.md conventions; no `Co-Authored-By`):

1. `paseo: <OLD> -> <NEW>` (no `v`): pin, hash, rebased/dropped patches,
   required module/test fixes. Short body listing dropped/rebased patches.
2. New hardening (patch, pin, test) as separate commits after, e.g.
   `paseo: disable <feature>`.

Keep the `phlip9/<NEW>` branch in `~/dev/paseo` (one commit per patch).
Don't push, open a PR, or deploy unless asked.

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
