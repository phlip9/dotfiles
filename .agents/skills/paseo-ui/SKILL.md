---
name: paseo-ui
description: Use to implement or fix phlip9's paseo UI feature requests (web app + any daemon/protocol support) as downstream patches in pkgs/paseo, verified in a real browser on desktop and phone
---

# paseo UI

Implement a UI change in paseo as a downstream patch (`pkgs/paseo/*.patch`),
prove it works in a real browser on desktop and phone, then ship it as a
dotfiles commit. phlip9 deploys; you never push or deploy.

Flow:

1. clarify -> 2. setup -> 3. research -> 4. implement -> 5. check ->
6. visual verify -> 7. export + build -> 8. commit + report

All tooling lives in `scripts/paseo-dev`. Run it from inside the dotfiles
worktree, aliased as `P=.agents/skills/paseo-ui/scripts/paseo-dev`.

## Model

- `pkgs/paseo/*.patch` is the source of truth, listed in order in
  `pkgs/paseo/default.nix` w/ one comment each. Tests for a patch live in
  `pkgs/paseo/tests/<name>.patch`. Upstream's nix src filter strips test
  files, so the package build applies only the main patch.
- `paseo-dev setup` creates `tmp/paseo`, a git worktree of `~/dev/paseo` at
  the pinned tag (`npins/sources.json`) on branch `wt/<dotfiles-worktree>`,
  w/ one commit per patch (subject == patch stem). It has its own
  `node_modules`, so concurrent agents don't collide (~1.5 min).
- Edit in `tmp/paseo`, fold edits into patch commits (`new` / `fixup`), then
  `export` regenerates `pkgs/paseo`. Never hand-edit `.patch` files.
- The web UI ships inside the daemon (`paseo.phlip9.com`). phlip9 mostly
  uses it in a **phone browser**. Native iOS/Android builds are not shipped:
  native code must typecheck, and the simplest fallback is fine.

## 1. Clarify

Requests are usually one-liners w/ a screenshot. Before coding, ask w/
`AskUserQuestion` (2-4 questions, concrete options, recommended first):

- placement: where on screen; which panel/surface; pinned vs scrolls w/
  content
- content: exactly which fields; truncation vs full; empty states
- format: font (mono vs UI), wrapping, relative vs absolute dates
- phone behavior: compact layout often differs (sheets, hidden sidebars)
- delivery: downstream patch only (default) vs also prep an upstream PR
  (prep only, never open one unasked)

Ask about behavior on scroll and on narrow screens up front. Last time, all
of the post-review feedback was about those, plus alignment.

## 2. Setup

```bash
P=.agents/skills/paseo-ui/scripts/paseo-dev
$P setup     # or: status (already set up), reset (rebuild from pkgs/paseo)
```

If `status` says DIFFERS for a worktree you didn't touch, master moved:
`$P reset` (refuses to drop unexported work w/o `--force`).

## 3. Research

Read upstream docs first (`tmp/paseo/AGENTS.md` lists them); they encode
conventions the code won't tell you. Always skim `docs/design.md`
(tokens, hierarchy, density, alignment, forbidden patterns),
`docs/coding-standards.md`, `docs/unistyles.md` (`useUnistyles()` is
forbidden), and as relevant `docs/i18n.md`, `docs/hover.md`,
`docs/mobile-panels.md`, `docs/protocol-compatibility.md`,
`docs/testing.md`.

Use an Explore subagent for wide code searches. Code map
(`packages/app/src` unless noted):

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
- `packages/protocol/src/messages.ts`: zod wire schemas. New fields are
  `.optional()` w/ a comment (old daemons omit them).
- `packages/server/src/`: daemon. Git data: `utils/checkout-git.ts`;
  session RPC handlers: `server/session/`.
- `packages/app/e2e/`: Playwright specs, `support/fixtures.ts`
  (`withWorkspace`), `support/helpers/*` (navigation flows).

## 4. Implement

Patch hygiene (patches get rebased on every paseo upgrade):

- One patch per feature, named `paseo-<feature>`. A follow-up change to a
  feature folds into its patch (`fixup`), not a new patch.
- Minimize churn in upstream files: new logic goes in new files (e.g.
  `git/commit-message-header.tsx`); upstream files get a small hook-in.
- Match upstream style; the formatter is `oxfmt`, not prettier.
- Generic extension points over feature hacks (e.g. `leadingContent` on
  the diff document instead of commit-specific code in the canvas).
- New wire fields: optional + backward-compatible both ways.

UI gotchas we've hit:

- Mixed fonts on one row (UI + mono): `alignItems: "baseline"`, or text
  baselines visibly drift.
- Selectable text: `selectable` on `Text`. Inside the canvas diff, stop
  pointer/contextmenu/copy propagation so the diff's handlers don't eat it.
- Long content must not starve the main view on phone: decide pinned vs
  scrolling explicitly (it's a clarify question).
- `Text` on web is `white-space: pre-wrap`: preformatted text keeps
  spacing and soft-wraps.

Commit work into the patch stack:

```bash
$P new paseo-<feature>      # first commit of a new patch
$P fixup paseo-<feature>    # fold further edits into it (autosquash)
```

## 5. Check

```bash
$P check            # scope: changes since setup/last export
$P check --all      # whole patch stack (before export, after upgrades)
```

`check` = oxfmt (writes) + oxlint on changed files, rebuilds workspace deps
if protocol/client changed, typechecks protocol/server/app, runs `vitest
related` per package (e2e excluded, git config isolated, memory-capped).

A failing test isn't necessarily yours. Run `$P baseline <pkg> <file>
[-t name]`, which runs it at the release tag and at HEAD. Fails at both:
upstream, note it and move on. Fails only at HEAD: ours. Bisect w/
`git -C tmp/paseo switch --detach <patch commit>`, then switch back to
`wt/<name>`. Also run the whole file, not just `-t`: fake-timer suites
can fail only in file order.

Add unit tests for non-trivial logic (parsers, hooks) next to upstream's
(`*.test.ts`); they export to `pkgs/paseo/tests/`. Upstream: TDD, real deps
over mocks (`docs/testing.md`). Never run whole suites (`npm run test`,
full Playwright); they freeze the host.

## 6. Visual verify (mandatory for UI)

Typecheck + unit tests don't catch layout bugs. Last time, misalignment and
scroll behavior shipped because the UI wasn't viewed before handoff.

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
  nix build compiles the full web bundle and server.
- Confirm a distinctive identifier of the change is in the bundle:

  ```bash
  web=tmp/paseo-build/result/lib/paseo/packages/server/dist/server/web-ui
  grep -l <testID> $web/_expo/static/js/web/index-*.js
  ```

## 8. Commit + report

Dotfiles commits (repo conventions, no `Co-Authored-By`):

- new feature: `paseo: <what it does>` (patch + default.nix entry)
- change to an existing patch: `paseo: <feature>: <what changed>`
- unrelated fix found along the way (e.g. formatting drift in another
  patch): separate commit.
- tooling/skill improvements: `ai: paseo-ui: <what>`, separate commit.

Report: what changed (user-visible), design decisions you made beyond the
agreed spec (call them out so phlip9 can veto), verification (commands,
screenshots viewed, desktop + phone), anything unverified, pre-existing
failures found. Don't push, PR, or deploy unless asked.

Leave `tmp/paseo` in place for review follow-ups (`$P clean` when done;
it refuses to drop unexported work).

## Improve this skill

After each run, fix friction in `SKILL.md` / `scripts/paseo-dev` in a
separate `ai: paseo-ui: ...` commit. Shellcheck manually (`just bash-lint`
skips hidden dirs):

```bash
nix shell -f . pkgs.shellcheck --command shellcheck \
  .agents/skills/paseo-ui/scripts/paseo-dev \
  .agents/skills/paseo-upgrade/scripts/*.sh
```
