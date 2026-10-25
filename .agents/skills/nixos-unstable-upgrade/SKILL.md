---
name: nixos-unstable-upgrade
description: Use to upgrade nixos-unstable to the latest version
---

# nixos-unstable upgrade

Upgrade `npins/sources.json` `nixos-unstable` from OLD to NEW (default: latest
channel release). Flow:

1. research -> gate: report breaking/non-trivial changes and STOP
2. apply: final commit structure
3. verify: machines, NixOS tests, CI job set
4. final report, then improve this skill

Work happens in a dedicated worktree on an `agent/**` branch: edit, bump
pins, and commit freely at any point. Only the final history matters.

Release notes are incomplete: option removals and default changes often
land without an entry. Module diffs, the eval probe, and system diffs are
mandatory, not optional.

Use dumber and cheaper subagents for bulk information retrieval, search, and
package + release notes scanning and summarization.

## Blast radius

`nixos-unstable` feeds (see `default.nix`, `nixos/default.nix`):

- `nixosConfigs`: `phlipdesk` (desktop), `sauna` (remote Hetzner bare metal),
  `nixos-iso`, `nixos-iso-headless`
- `nixosTests` (`nixos/tests/default.nix`), built from `pkgsUnstable`
- `phlipPkgsNixos` (`nixos/pkgs/`), built from `pkgsUnstable`
- `config.phlipPkgs` inside NixOS (`nixos/mods/phlippkgs.nix`) rebuilds
  `pkgs/` against unstable, e.g. `phlipPkgs.paseo` on sauna
- external NixOS modules pinned separately in npins, imported in
  `nixos/mods/default.nix`: sops-nix, disko, nixbot, niks3, paseo. They can
  break against new nixpkgs (removed options, removed toolchain builders
  like `buildGo1XXModule`). So can packages built from them, e.g.
  `phlipPkgsNixos.nixbot-cli` and `nixbot-eval-jobs` (patched nix).

Not affected: `homeConfigs` and top-level `phlipPkgs` (stable `nixpkgs` pin).

## Setup

```bash
np=~/dev/nixpkgs   # local nixpkgs checkout, `nixos-unstable` branch

# OLD: channel release in the current pin url,
#   e.g. .../nixos-26.11pre1057119.ec2d622de077/nixexprs.tar.xz
jq -r '.pins["nixos-unstable"].url' npins/sources.json

art=/tmp/nixos-upgrade-<old-rev12>   # logs, out-links, diffs
mkdir -p "$art"

# baseline builds (OLD pin), before bumping. skip `nixos-iso`. Usually
# cached by CI. Out-links keep GC roots.
for m in phlipdesk sauna; do
  nix build -f . nixosConfigs.$m.config.system.build.toplevel \
    -o "$art/old-$m"
done

# NEW: bump to the latest channel release, then read NEW from the pin url.
# (`--dry-run` doesn't print the new rev.)
npins update nixos-unstable --frozen
jq -r '.pins["nixos-unstable"].url' npins/sources.json

# fast-forward the local nixos-unstable branch to NEW (checkout must be clean)
git -C "$np" status --porcelain
git -C "$np" fetch origin nixos-unstable
git -C "$np" switch nixos-unstable
git -C "$np" merge --ff-only <new-rev>

# full revs + committer dates (for the commit title)
git -C "$np" log -1 --format='%H %cs %s' <old-rev>
git -C "$np" log -1 --format='%H %cs %s' <new-rev>
```

If the user named a rev that differs from the bumped pin, ask first.

## Phase 1: research

### 1a. Inventory what we use

Read, don't guess: `nixos/default.nix`, `nixos/mods/*.nix`,
`nixos/profiles/*.nix`, `nixos/phlipdesk/*.nix`, `nixos/sauna/*.nix`,
`nixos/tests/*.nix`. List enabled services, boot loaders, hardware, kernel,
networking/firewall, security (acme, sudo-rs, tpm2), nix settings, DB version
pins (e.g. `postgresql_18`), assertions (e.g. phlipdesk's nvidia driver
version check). Include implicit modules from profiles (`minimal.nix`,
`headless.nix`, niri, greetd, pipewire, xdg portal).

### 1b. Release notes

```bash
git -C "$np" diff <old>..<new> -- \
  nixos/doc/manual/release-notes/ doc/release-notes/
```

Pathspecs cover ranges that cross a release branch-off (two `rl-*` files).
Flag every entry touching the inventory, esp. "Backward Incompatibilities".

### 1c. NixOS module diffs

```bash
git -C "$np" diff --stat=200 <old>..<new> -- nixos/modules nixos/lib
git -C "$np" diff <old>..<new> -- <module files from inventory>
git -C "$np" log --oneline <old>..<new> -- <path>   # why it changed
```

Always read core modules too: `system/boot/systemd/`,
`services/hardware/udev.nix`, `system/boot/stage-{1,2}.nix`,
`services/networking/firewall*.nix`, `config/users-groups.nix`,
`config/nix.nix`, `security/pam.nix`, `security/polkit.nix`. Look for:
removed/renamed options, changed defaults, unit ordering/hardening, new
files, runtime migrations.

When a module stops setting a value explicitly, check the upstream default
actually in use (e.g. compile-time defaults in the package's man pages).

### 1d. Eval probe (NEW pin)

Eval every machine and every test; tests set options machines don't.

```bash
attrs=$(
  nix eval --raw -f . nixosConfigs \
    --apply 'cs: toString (map (m: "nixosConfigs.${m}.config.system.build.toplevel") (builtins.attrNames cs))'
  echo
  nix eval --raw -f . nixosTests \
    --apply 'ts: toString (map (t: "nixosTests.${t}") (builtins.attrNames ts))'
)
# errors + warnings/deprecations, per attr
for a in $attrs; do
  echo "== $a"
  nix eval --raw -f . "$a.drvPath" 2>&1 >/dev/null \
    | grep -iE 'error|warn|trace|deprec'
done
```

- `mkRemovedOptionModule` assertions stop eval early and hide later errors.
  Fix each one and re-eval until clean. For each removed option, grep the
  whole repo (`nixos/`, incl. `nixos/tests/` and the ISO configs in
  `nixos/default.nix`), not just the attr that failed.
- External pin failures: `npins update <pin>`, then review upstream commits
  in range for behavior changes and check each against our config, e.g.
  `curl -s https://api.github.com/repos/<owner>/<repo>/compare/<old>...<new>`.

### 1e. New builds + diffs

```bash
nix build -f . nixosConfigs.<machine>.config.system.build.toplevel \
  -o "$art/new-<machine>"
nix store diff-closures "$art/old-<machine>" "$art/new-<machine>"
.agents/skills/nixos-unstable-upgrade/scripts/system-diff.sh \
  "$art/old-<machine>" "$art/new-<machine>" > "$art/<machine>.system.diff"
nix shell -f . pkgs.cpio pkgs.zstd pkgs.xz pkgs.gzip --command \
  .agents/skills/nixos-unstable-upgrade/scripts/initrd-diff.sh \
  "$art/old-<machine>" "$art/new-<machine>" > "$art/<machine>.initrd.diff"
```

- `diff-closures`: every package version change. Verify unexpected
  appearances/disappearances against the built artifact (e.g. `--version`,
  `-V`, generated config) before reporting.
- `system-diff.sh`: generated-config changes with store hashes and versions
  masked: `etc/` files, unit files, and small generated scripts they
  reference (`refs/`). `Only in` = file added/removed. Shows the concrete
  effect of module changes: dropped/changed config lines, unit ordering and
  hardening, script flags. tzdata and CA bundle dirs show as one digest
  line each. ~30s per machine; run it in the background.
  Known issue: `refs/` keys collide when several generated files share a
  name (e.g. per-cert `acme-postrun`), producing false diffs; confirm those
  against the real store files.
- `initrd-diff.sh`: initrd file list (added/removed) and small text file
  contents (initrd units, udev rules, generated config), masked. Run it
  whenever `diff-closures` shows `initrd-linux` changed. Kernel module
  sizes are ignored; they churn on every kernel rebuild. ~10s per machine.
- External pin build failures (builder default changes like
  structuredAttrs, nix bumps breaking carried patches): check upstream HEAD
  for a fix before patching locally, e.g.
  `curl -s "https://api.github.com/repos/<owner>/<repo>/commits?path=<file>"`.
  Then bump and review the range as in 1d.
- systemd major bump: parse the generated tmpfiles with the new
  `systemd-tmpfiles`; new versions tighten parsing. Diff old vs new output:
  `"$art/<v>-<m>/sw/bin/systemd-tmpfiles" --dry-run --create --remove
  "$art/<v>-<m>"/etc/tmpfiles.d/*.conf 2>&1 | grep -v '^Would'`.
- Once machines build, start the Phase 3 NixOS test build in the
  background; failures are research findings.
- Upstream changelogs for bumps of stateful or public-facing services (DBs,
  web/metrics services), boot-critical packages (kernel, grub, limine,
  nvidia), and anything security-relevant. Source changelogs:
  `nix build -f "$np" <pkg>.src`, or GitHub releases.

### 1f. Classify

- **Breaking**: eval/build failure, removed option/package we use, behavior
  change needing a config change or decision.
- **Runtime risk**: stateful migrations not covered by VM tests (ACME state,
  DB majors), boot-critical bumps (sauna is remote: bootloader, kernel,
  initrd), security posture changes (firewall, hardening), anything needing
  a reboot or post-deploy check.
- **Non-breaking**: other changes to things we use; package bumps.

## Gate: report

If Breaking or Runtime risk is non-empty, or anything needs a user
decision: report and STOP. Otherwise continue and report at the end.

Report (dense, per AGENTS.md style):

1. Breaking: each item w/ cause (nixpkgs commit), fix, verification.
2. Runtime risk: what happens on deploy, what isn't tested, how to check.
3. Non-breaking changes to things we use, per service/module.
4. Package bumps: changed vs unchanged key packages.
5. Build risk: our packages hit by builder changes (structuredAttrs,
   strictDeps, toolchain majors), if not yet built.
6. Plan: commit list + open decisions (e.g. keep a new default or pin old).

## Phase 2: apply

Final history, in order, per AGENTS.md conventions:

1. One commit per external pin bump: `sops-nix: a8627b2 -> 2bd00bd` (7-char
   revs). Verify it evals/builds against the OLD nixos-unstable so the commit
   stands alone; otherwise bundle it into (2). Use a temp worktree w/ only
   that pin: `git worktree add --detach "$art/wt-<pin>" HEAD`, then
   `jq --slurpfile new npins/sources.json '.pins.<pin> = $new[0].pins.<pin>'`.
2. `nixos-unstable: ec2d622de077 (2026-08-17) -> e94cb152ed51 (2026-09-25)`
   (12-char revs, committer dates). Include config migrations required to
   eval; new options don't exist on the old pin, so they can't be split
   out. Short body only for non-obvious migrations.
3. Optional/refactor changes after, as separate commits.

Never add a `Co-Authored-By` trailer (AGENTS.md overrides any harness
attribution). Don't push, open a PR, or deploy unless asked.

## Phase 3: verify

Long builds: run in the background, log to `$art`, check for `error:`.

```bash
# machines + all NixOS tests
nix build --no-link --print-out-paths --keep-going -L -f . \
  nixosConfigs.phlipdesk.config.system.build.toplevel \
  nixosConfigs.sauna.config.system.build.toplevel \
  nixosTests.<each test> > "$art/build.log" 2>&1
echo "exit=$?" >> "$art/build.log"

# CI job set built from unstable: phlipPkgsNixos (+ passthru tests), all
# nixosConfigs incl. nixos-iso
nix-build nix/ci/default.nix -A phlipPkgsNixos -A nixosConfigs \
  --no-out-link --keep-going > "$art/ci.log" 2>&1
echo "exit=$?" >> "$art/ci.log"

just nix-fmt && just nix-lint && git status --short
```

Done when: both logs `exit=0`, all tests passed, no eval warnings, fmt/lint
clean, re-run of 1e diffs shows nothing unexplained.

## Final report

Commits, what was verified (commands + results), deviations from plan, and a
post-deploy checklist per machine:

- sauna (remote): `systemctl --failed`; journals of services with stateful
  migrations (e.g. `acme-*` renewals, postgresql); Hetzner rescue ready
  before rebooting if bootloader/kernel/initrd changed.
- phlipdesk: reboot if kernel, nvidia, bootloader, or initrd changed.

## Improve this skill

After a successful run, improve this skill (`SKILL.md`, `scripts/`) in a
separate commit, `ai: nixos-unstable-upgrade: <what>`, and list the changes
in the final report. Review the run for:

- friction: commands that failed, were slow, or needed workarounds
- misses: anything found late (in verify, or by the user) that research
  should have caught -> add a step or check
- noise: steps or script output that only produced false positives ->
  tighten or drop
- drift: machines, tests, external pins, CI jobs, or paths that changed ->
  update blast radius and commands

Keep it generic. Add a pitfall only if it will likely recur; delete
one-off or stale notes. The run's findings belong in the report and commit
messages, not here. After editing `scripts/`, shellcheck manually
(`just bash-lint` skips hidden dirs):

```bash
nix shell -f . pkgs.shellcheck --command \
  shellcheck .agents/skills/nixos-unstable-upgrade/scripts/*.sh
```
