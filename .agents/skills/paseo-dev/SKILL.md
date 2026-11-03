---
name: paseo-dev
description: Use to implement, fix, or maintain phlip9's downstream paseo patches in pkgs/paseo (UI features, daemon/CLI/protocol behavior, security hardening) and their tests
---

# paseo patch development

Change paseo through a downstream patch (`pkgs/paseo/*.patch`), prove it
works (tests, plus a VM test or a real browser depending on the change),
then ship it as a dotfiles commit. phlip9 deploys; you never push or
deploy.

Flow:

1. clarify -> 2. setup -> 3. research -> 4. implement -> 5. check ->
6. verify -> 7. export + build -> 8. commit + report

UI work adds UI-specific steps; see [UI work](#ui-work).

All tooling lives in `scripts/paseo-dev`. Run it from inside the dotfiles
worktree, aliased as `P=.agents/skills/paseo-dev/scripts/paseo-dev`.

## Model

- `pkgs/paseo/*.patch` is the source of truth, listed in order in
  `pkgs/paseo/default.nix` w/ one comment each. Tests for a patch live in
  `pkgs/paseo/tests/<name>.patch`. Upstream's nix src filter strips test
  files, so the package build applies only the main patch. Upstream tests
  that conflict w/ a patch are listed in `pkgs/paseo/tests/ignored.json`.
- `paseo-dev setup` creates `tmp/paseo`, a git worktree of `~/dev/paseo` at
  the pinned tag (`npins/sources.json`) on branch `wt/<dotfiles-worktree>`,
  w/ one commit per patch (subject == patch stem). It has its own
  `node_modules`, so concurrent agents don't collide (~1.5 min).
- Edit in `tmp/paseo`, fold edits into patch commits (`new` / `fixup`), then
  `export` regenerates `pkgs/paseo`. Never hand-edit `.patch` files.
- The daemon runs on sauna (`services.paseo`, `nixos/mods/paseo.nix`) and
  on other hosts via home-manager (`home/mods/paseo.nix`). Daemon access ==
  full control of the host as phlip9, so security patches fail closed.
- Upgrades rebase every patch onto a new release (`paseo-upgrade` skill),
  so each patch's size and spread is an ongoing cost.

## 1. Clarify

Requests are often one-liners. Before coding, ask w/ `AskUserQuestion`
(2-4 questions, concrete options, recommended first) about whatever is
fuzzy:

- behavior: exact inputs/outputs, edge and empty cases, error handling
- scope: which surfaces (daemon, CLI, app, relay), which hosts
- security changes: fail-closed behavior, what may break for clients,
  whether a config knob exists upstream (prefer it over a patch)
- delivery: downstream patch only (default) vs also prep an upstream PR
  (prep only, never open one unasked)

UI requests have their own question list in [UI work](#ui-work).

## 2. Setup

```bash
P=.agents/skills/paseo-dev/scripts/paseo-dev
$P setup     # or: status (already set up), reset (rebuild from pkgs/paseo)
```

If `status` says DIFFERS for a worktree you didn't touch, master moved:
`$P reset` (refuses to drop unexported work w/o `--force`).

## 3. Research

Read upstream's agent docs first: `tmp/paseo/CLAUDE.md` (rules + docs
index), `packages/server/CLAUDE.md` for daemon work. They encode
conventions the code won't tell you. As relevant: `docs/architecture.md`,
`docs/coding-standards.md`, `docs/protocol-compatibility.md`,
`docs/rpc-namespacing.md`, `docs/permissions.md` + `SECURITY.md` (auth,
relay), `docs/testing.md`.

Use an Explore subagent for wide code searches. Code map:

- `packages/server/src/`: daemon. `server/bootstrap.ts` (wiring),
  `server/websocket-server.ts` (sockets, hello admission),
  `server/session-admission-auth.ts`, `server/config*.ts` (env + config),
  `server/session/` (RPC handlers), `utils/checkout-git.ts` (git data),
  `utils/run-git-command.ts`.
- `packages/protocol/src/messages.ts`: zod wire schemas.
- `packages/client/src/daemon-client.ts`: client RPC methods.
- `packages/cli/src/`: CLI (`utils/client.ts` connects to daemons).
- `packages/app/src/`: Expo app (web UI); see [UI work](#ui-work).
- Our patches: `git -C tmp/paseo log --stat v<tag>..` shows what each one
  touches; read the neighbors of the code you change.

## 4. Implement

Patch hygiene:

- One patch per feature, named `paseo-<feature>`. A follow-up change to a
  feature folds into its patch (`fixup`), not a new patch.
- Minimize churn in upstream files: new logic goes in new files; upstream
  files get a small hook-in.
- Match upstream style and rules (`CLAUDE.md`): the formatter is `oxfmt`,
  not prettier; server imports use relative `.js` paths.
- Generic extension points over feature hacks (e.g. `leadingContent` on
  the diff document instead of commit-specific code in the canvas).
- New wire fields: `.optional()` w/ a comment, backward-compatible both
  ways (old daemons and clients omit them).
- Security patches: smallest change that closes the hole, fail closed,
  comment why at the change site.

Commit work into the patch stack:

```bash
$P new paseo-<feature>      # first commit of a new patch
$P fixup paseo-<feature>    # fold further edits into it (autosquash)
```

## 5. Check

```bash
$P check            # scope: changes since setup/last export
$P check --all      # whole patch stack (before export, after upgrades)
$P test <pkg> <file> [-t name]   # one test file, same env as check
```

`check` = upstream's `format:files` (writes) + `lint` npm scripts on changed
files (incl. deleted ones, for scope), rebuilds workspace deps if
protocol/client changed (and the server if cli changed: cli imports its
dist; clean builds if a source was deleted, else stale dist/ outputs still
resolve), typechecks protocol/server/app + every touched package, runs
`vitest related` in every touched vitest package (e2e excluded,
memory-capped).

Tests run in a CI-like env: PATH is pinned node + gh + ripgrep + the NixOS
system profile (no user profile: a host-installed `codex` breaks upstream
tests), and no user git config (commit signing breaks test repos).

`check --all` is green on the current stack, so any failure is new. Run
`$P baseline <pkg> <file> [-t name]`, which runs it at the release tag and
at the patch branch, each w/ its own clean workspace builds (~3-5 min),
and prints each exit code + full log path. Fails at both: upstream or
env, note it and move on. Fails only at the branch: ours. Bisect w/
`git -C tmp/paseo switch --detach <patch commit>`, then switch back to
`wt/<name>`: `new`, `fixup`, `export`, and `clean` refuse to run off the
branch. Also run the whole file, not just `-t`: fake-timer suites can fail
only in file order.

Never edit upstream test files: every edit is a rebase conflict on the
next upgrade.

- Upstream test conflicts w/ our patch: add it to
  `pkgs/paseo/tests/ignored.json` (`{patch, file, test, reason}`; omit
  `test` to drop a whole file whose suite is all disabled-feature tests).
  `paseo-dev` runs vitest through a generated, git-excluded wrapper config
  that excludes/skips these. `test` is the full name: describe titles +
  test title joined w/ ` > ` (it.each: each expanded title). A run fails
  if an entry matches no test or several, its file is gone, or its patch
  isn't active in `default.nix`, so stale entries surface on upgrades.
- Our behavior: test it only where it adds value, in a new file owned by
  the patch (`<area>.<feature>.test.ts`, top comment
  `// paseo-<name>: ...`). It folds into the patch's commit and exports to
  `pkgs/paseo/tests/<name>.patch`. Skip it when `nixosTests.paseo` already
  covers the behavior end to end (relay password, plugin installs,
  password file, env scrub) or the patch is a constant tweak.
- Mutation-check new tests: revert the patch's code, the test must fail,
  restore.

Upstream: TDD, real deps over mocks (`docs/testing.md`). Never run whole
suites (`npm run test`, full Playwright); they freeze the host.

## 6. Verify

Unit tests prove the logic; verify the change in its real environment too.
Pick by what the patch changes:

- Daemon behavior seen through its config, env, auth, or processes
  (hardening, credentials, child envs, relay): `nixosTests.paseo`
  (`nixos/tests/paseo.nix`) runs the packaged daemon, relay, CLI, and nginx
  in a VM. For a security-relevant patch, add a subtest that drives it
  from outside (CLI/curl) and mutation-check it: comment out the patch in
  `default.nix`, the subtest must fail, restore. Run via `$P build` +
  `$P vmtest` (step 7).
- UI: browser visual check, mandatory; see
  [UI work: visual verify](#ui-visual-verify).
- Pure logic (parsers, git data): unit tests from step 5 are enough.

## 7. Export + build

```bash
$P export            # writes pkgs/paseo/*.patch + tests/, reports drift
# new patch: add `./paseo-<feature>.patch` + a 1-2 line comment at the end
# of `patches` in pkgs/paseo/default.nix
$P build             # nix build -f . paseo (5-10 min; run in background)
$P vmtest            # nixosTests.paseo (~2 min after build)
just nix-ci
```

- `export` skips patches that differ only in `index` lines, so an
  unchanged stack exports as a no-op.
- `build` failure: grep `tmp/paseo-build/build.log` for `error TS`; the
  nix build compiles the server, CLI, and full web bundle.
- Run `vmtest` for every patch change: it's the end-to-end guard for the
  security patches, whatever you changed.

## 8. Commit + report

Dotfiles commits (repo conventions, no `Co-Authored-By`):

- new feature: `paseo: <what it does>` (patch + default.nix entry)
- change to an existing patch: `paseo: <feature>: <what changed>`
- VM test changes go w/ the patch they test.
- unrelated fix found along the way (e.g. formatting drift in another
  patch): separate commit.
- tooling/skill improvements: `ai: paseo-dev: <what>`, separate commit.

Report: what changed (user-visible), design decisions you made beyond the
agreed spec (call them out so phlip9 can veto), verification (commands,
tests, VM subtests, screenshots viewed), anything unverified, pre-existing
failures found. Don't push, PR, or deploy unless asked.

Leave `tmp/paseo` in place for review follow-ups (`$P clean` when done;
it refuses to drop unexported work).

## UI work

The web UI ships inside the daemon (`paseo.phlip9.com`). phlip9 mostly uses
it in a **phone browser**. Native iOS/Android builds are not shipped: native
code must typecheck, and the simplest fallback is fine.

### UI clarify

Requests are usually a one-liner w/ a screenshot. Ask about:

- placement: where on screen; which panel/surface; pinned vs scrolls w/
  content
- content: exactly which fields; truncation vs full; empty states
- format: font (mono vs UI), wrapping, relative vs absolute dates
- phone behavior: compact layout often differs (sheets, hidden sidebars)

Ask about behavior on scroll and on narrow screens up front. On the first
UI patch, all of the post-review feedback was about those, plus alignment.

### UI research

Also skim upstream `docs/design.md` (tokens, hierarchy, density,
alignment, forbidden patterns), `docs/unistyles.md` (`useUnistyles()` is
forbidden), and as relevant `docs/i18n.md`, `docs/hover.md`,
`docs/mobile-panels.md`.

App code map (`packages/app/src`):

- `panels/`: workspace tab panels. `definePanel(kind, {component,
  useDescriptor})`; tab label/icon via descriptor. `diff-panel.tsx` holds
  the working diff + commit diff panels.
- `git/`: changes/diff/commits UI, react-query hooks (`use-*-query.ts`,
  `use-diff-files.ts`). `git/diff-document/` is a canvas-rendered,
  virtualized diff (`surface.web.tsx`, `surface.native.tsx`, `model.ts`):
  don't put DOM content inside it; use its `leadingContent` slot (ours,
  from `paseo-commit-message`) or render around it.
- `components/ui/`: primitives (toolbar, buttons, menus, sheets).
- `styles/theme.ts`: tokens: `theme.spacing[n]`, `theme.fontSize.{sm,base,
  code,...}`, `theme.fontWeight.*`, `theme.colors.{foreground,
  foregroundMuted,border,...}`, `theme.fontFamily.{ui,mono}`. Styles via
  `StyleSheet.create((theme) => ...)` from `react-native-unistyles`.
- `styles/code-surface.ts`: put `dataSet={CODE_SURFACE_DATASET}` on mono
  text, else web's root UI-font rule overrides it.
- `i18n/resources/*.ts`: user-visible strings go in `en.ts` and every
  locale (parity test: `src/i18n/resources.test.ts`).
- `constants/layout.ts`: `useIsCompactFormFactor()` (phone layout).
- `*.web.tsx` / `*.native.tsx`: platform splits; edit both or neither.
- `packages/app/e2e/`: Playwright specs, `support/fixtures.ts`
  (`withWorkspace`), `support/helpers/*` (navigation flows).

### UI gotchas

- Mixed fonts on one row (UI + mono): `alignItems: "baseline"`, or text
  baselines visibly drift.
- Selectable text: `selectable` on `Text`. Inside the canvas diff, stop
  pointer/contextmenu/copy propagation so the diff's handlers don't eat it.
- Long content must not starve the main view on phone: decide pinned vs
  scrolling explicitly (it's a clarify question).
- `Text` on web is `white-space: pre-wrap`: preformatted text keeps
  spacing and soft-wraps.

### UI visual verify

Typecheck + unit tests don't catch layout bugs. On the first UI patch,
misalignment and scroll behavior shipped because the UI wasn't viewed
before handoff.

```bash
$P visual <slug>     # scaffolds packages/app/e2e/browser/agent-<slug>.spec.ts
# edit it: seed repo state, drive to the feature, assert, shoot
$P e2e e2e/browser/agent-<slug>.spec.ts
```

- Runs upstream's Playwright harness (Metro dev bundle + isolated e2e
  daemon per worker) against nixpkgs chromium. ~40s warm, workers=1,
  memory-capped. Screenshots land in `tmp/paseo-shots/`; view them w/
  `Read`.
- Shoot **desktop (1400x900) and phone (390x844)**, initial + after the
  interaction (scroll, expand, tap). The helpers navigate via the
  desktop sidebar, so navigate at desktop size, then
  `page.setViewportSize(PHONE)`.
- Detail checks (alignment, spacing): `shootElement` + zoom w/
  imagemagick (command in the template).
- Assert behavior in the spec too (`toBeInViewport`, counts, text), so a
  regression fails the run instead of relying on eyeballing.
- `agent-*.spec.ts` is git-excluded and never exported. If the flow is
  worth guarding long term, write a proper spec under a real name; it
  exports to `pkgs/paseo/tests/`.
- Iterate: edit -> `fixup` -> `e2e` until the screenshots match the agreed
  design. Metro serves source, so no package build in the loop.
- After `$P build`, confirm a distinctive identifier of the change is in
  the shipped bundle:

  ```bash
  web=tmp/paseo-build/result/lib/paseo/packages/server/dist/server/web-ui
  grep -l <testID> $web/_expo/static/js/web/index-*.js
  ```

## Improve this skill

After each run, fix friction in `SKILL.md` / `scripts/paseo-dev` in a
separate `ai: paseo-dev: ...` commit. Shellcheck manually (`just bash-lint`
skips hidden dirs):

```bash
nix shell -f . pkgs.shellcheck --command shellcheck \
  .agents/skills/paseo-dev/scripts/paseo-dev \
  .agents/skills/paseo-upgrade/scripts/*.sh
```
