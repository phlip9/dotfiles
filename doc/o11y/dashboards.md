# Grafana dashboards: agent-managed, git-backed

Research + plan for making Grafana dashboards on `sauna` ergonomic:
(1) let an agent (Claude Code) create/edit dashboards with repo context, and
(2) keep dashboards in the dotfiles git repo for history/backup without
redeploying to tweak a panel.

- date: 2026-10-25
- grafana: 13.2.4 OSS (nixos-unstable 3ec636362e18)
- sources: `~/dev/grafana` (v13.2.4), `~/dev/nixpkgs` (3ec636362e18),
  `~/dev/mcp-grafana` (v2.1.1), `~/dev/grafanactl` (v0.1.10), `~/dev/gcx`
  (v1.6.0), `~/dev/grafana-llm-app` (v1.2.0+1).
- constraint: OSS only. No Grafana Cloud / Enterprise.

## TL;DR

- Grafana 13 OSS ships "Git Sync" (`provisioning.grafana.app`): bidirectional
  sync of dashboards + folders with a git repo. Already enabled on sauna, no
  feature toggle needed. UI "Save" on a synced dashboard becomes a git commit
  (direct to branch, or new branch + PR). API writes (incl. mcp-grafana) are
  re-routed to the same path, so agent edits also become commits.
- Agent bridge: `mcp-grafana` v2.1.1 (nixpkgs) over stdio. Natively speaks to
  our `victoriametrics-metrics-datasource`. `update_dashboard` does
  create/update/JSONPath-patch. Read-only mode via `--disable-write`.
- Skip `grafana-llm-app`: in OSS 13.2.4 it only adds 4 "auto-generate
  title/description" buttons; the real in-Grafana agent (Grafana Assistant)
  needs a Cloud stack backend.
- `grafanactl` is deprecated; `gcx` (nixpkgs 1.6.0) is the successor CLI for
  pull/push of dashboards as k8s-style manifests. Useful as a backup/restore
  and bulk-migration tool regardless of Git Sync.
- Classic file provisioning from the nix store is the wrong tool: every deploy
  that changes the dashboards dir re-imports and wipes UI edits.

## Current state (live, 2026-10-25)

Inspected via a read-only copy of `/var/lib/grafana/data/grafana.db` and the
admin API.

| uid            | title                              | apiVersion | panels |
|----------------|------------------------------------|------------|--------|
| `rYdddlPWk`    | Node Exporter Full                 | v1beta1    | 31     |
| `MsjffzSZz`    | NGINX                              | v1beta1    | 6      |
| `wGgaPlciz`    | Postgres Overview                  | v1beta1    | 7      |
| `wNf0q_kZk_vm` | VictoriaMetrics - single-node (VM) | v2         | n/a    |

- All in root folder, all hand-imported via UI, none provisioned.
- Dashboards live in unified storage (`resource` table, mode 5); the legacy
  `dashboard` table is empty. Version history: 27 rows in `resource_history`
  (`versions_to_keep` = 20 per dashboard).
- The VM dashboard was re-saved under Grafana 13.1.6 as schema **v2**
  (dynamic dashboards; `dashboardNewLayouts` is GA + on). v2 is not classic
  dashboard JSON and is not losslessly convertible back to v1.
- `GET /apis/dashboard.grafana.app` -> `preferredVersion = v2`. Tools
  that pull "dashboards" without pinning a version get v2 manifests.
- Git Sync API is live:
  `/apis/provisioning.grafana.app/v0alpha1/namespaces/default/settings` ->
  `availableRepositoryTypes: [git, github, local]`,
  `allowedTargets: [folder, folderless]`, `maxRepositories: 10`, resources
  Folder + Dashboard (LibraryPanel, Playlist declared but disabled). No
  repositories configured.
- No service accounts exist yet. Users: `admin`, `phlip9` (both Grafana
  Admin). Datasource: `victoriametrics` (plugin type, read-only).
- Feature toggles of note (all on): `dashboardNewLayouts`,
  `provisioning.gitConventions`, `provisioning.readmes`,
  `provisioning.userAttribution`, `provisioningFolderMetadata`.

## Findings

### Git Sync (Grafana 13.2.4 OSS)

Docs: `docs/sources/as-code/observability-as-code/git-sync/`,
`docs/sources/as-code/observability-as-code/provision-resources/`. Code:
`pkg/registry/apis/provisioning/`, `apps/provisioning/`.

- Gate is `[provisioning] enabled` (default true). The 12.x feature toggles
  (`provisioning`, `kubernetesDashboards`, ...) no longer exist in 13.x. Some
  docs pages still mention them (stale).
- Scope: dashboards + folders only. Not datasources, alert rules, contact
  points. `sync.target`: `folder` (wrapper folder named after the repo) or
  `folderless` (top level). `instance` is experimental and not in
  `allowed_targets` by default.
- Repository types in OSS (`pkg/registry/apis/provisioning/extras/register.go`):
  - `github`: PAT (fine-grained: Contents RW, Metadata R, Pull requests RW;
    Administration R + Webhooks RW only if webhook auto-registration is
    wanted) or GitHub App. Supports direct-commit ("write") and
    branch + PR ("branch") workflows, PR previews/comments, commit/branch/PR
    title templates, commit author = Grafana user. Webhook is optional:
    `spec.webhook.disabled: true` -> polling only.
  - `git`: generic HTTPS smart-http only (no ssh), user + token. Branch
    workflow creates a branch but no PR. Polling only. Loopback/private
    hosts rejected unless in `allowed_git_urls`.
  - `local`: a plain directory under `[paths] permitted_provisioning_paths`
    (default `devenv/dev-dashboards|conf/provisioning`, relative to
    homepath `/var/lib/grafana`, absolute ok). Write workflow only (no
    branch/commit/PR options; see
    `apps/provisioning/pkg/repository/validator.go:205`).
    Grafana never runs git (pure-Go nanogit for remote types; no `os/exec`).
    Not "versioned", so every `sync.intervalSeconds` does a full re-scan
    (hash compare; cheap at our size).
  - gitlab/bitbucket/GHE: Enterprise only.
- Polling: `spec.sync.intervalSeconds`, floor `[provisioning]
  min_sync_interval = 10s`, UI default 60s. Versioned repos skip sync when
  remote HEAD == `status.sync.lastRef`.
- Workflow semantics (`apps/provisioning/pkg/repository/workflows.go`):
  save to configured branch = commit + DB update immediately; save to other
  branch = commit only, DB untouched, redirect to preview with "Open PR"
  (github only). Git is the source of truth; a changed file overwrites the
  DB resource with the same uid. No merge UI; last write wins.
- API writes to a repo-managed resource by a non-provisioning identity via
  the k8s-style API (`PUT /apis/dashboard.grafana.app/v1/.../<uid>`, manager
  annotations preserved) are re-routed to the repository `files` endpoint
  and become a commit, message from the `grafana.app/message` annotation or
  "Update <uid>" (`pkg/storage/unified/apistore/managed.go`). Verified in
  the VM test. Caveats (also verified): the legacy `POST /api/dashboards/db`
  returns 400 "Cannot save provisioned dashboard" (`pkg/api/dashboard.go`),
  and a PUT that drops the manager annotations DETACHES the dashboard from
  the repo instead of writing the file. mcp-grafana `update_dashboard` uses
  the legacy endpoint for v1 (full JSON and patch modes), so it cannot edit
  synced v1 dashboards; v2 creates/updates go through the k8s API and work.
- File format: k8s manifest per resource, pretty JSON or YAML by extension
  (`apps/provisioning/pkg/resources/parser.go`):
  `{"apiVersion":"dashboard.grafana.app/v1","kind":"Dashboard",
  "metadata":{"name":"<uid>"},"spec":{...classic dashboard JSON...}}`.
  v2 dashboards use `apiVersion: dashboard.grafana.app/v2`. Bare classic
  JSON with `uid`/`panels`/`schemaVersion`/`tags` is also readable. Folders
  are `_folder.json`. `spec.uid/version/id` stripped on read. Max depth 8,
  max file 5 MiB.
- Classic file provisioning accepts the same `.json` manifests (top-level
  `apiVersion`), so one on-disk layout can serve both mechanisms.
- Migrating existing dashboards into a synced folder requires deleting the
  originals (uid conflict; `add-resources/dashboards-migrate.md`). Version
  history resets. Fine for our 4 dashboards.
- SECURITY: remote-type tokens are stored as secure values encrypted by the
  new secrets manager, keyed by `[secrets_manager.encryption.secret_key.v1]
  secret_key`, whose default is the PUBLIC string `SW2YcwTIb9zpOOhoPsMm`
  (`conf/defaults.ini`). It does NOT fall back to `[security] secret_key`
  (`pkg/registry/apis/secret/encryption/kmsproviders/kmsproviders.go`).
  Must override via `$__file{}` before storing any PAT. Not an issue for
  the `local` type.
- Repository resources cannot be provisioned from files; create via UI,
  API (`PUT /apis/provisioning.grafana.app/v0alpha1/namespaces/default/
  repositories/<name>`, token as `secure.token.create`), or gcx.
- Export menu: "Export as code" (Classic JSON | V2 Resource JSON/YAML; V2 is
  the default). No "export to git" item outside the Git Sync save drawer.

### Classic file provisioning (`[[dashboard providers]]`)

`pkg/services/provisioning/dashboards/file_reader.go`, NixOS module
`nixos/modules/services/monitoring/grafana.nix`.

- Change detection is md5 of file bytes vs stored checksum; `updateInterval
  <= 10s` uses fsnotify, else polling. The file's `version` field is ignored.
- `allowUiUpdates: true`: UI saves go to the DB only. They survive until the
  file's bytes change; then the file overwrites them. `false`: 400 "Cannot
  save provisioned dashboard", UI offers copy-JSON / save-as-copy.
- `disableDeletion`: file removed -> `true` unprovisions, `false` deletes.
  Removing or renaming a provider deletes all its dashboards at startup.
- NixOS module: `provision.dashboards.settings.providers[].options.path` is
  unconstrained (mutable dir ok). `provision.enable` is a no-op. The
  provisioning dir is a store symlink farm referenced from `config.ini`, so
  any change restarts grafana. Grafana stores absolute file paths, so a new
  store path for the dashboards dir makes all old entries "missing" and all
  new ones "new": every such deploy re-imports and wipes UI edits, even with
  `allowUiUpdates`. Conclusion: if classic provisioning is used at all, point
  it at a mutable dir outside the store (e.g. `/var/lib/grafana/dashboards`)
  and update that dir without touching the unit.
- grafana.service hardening: `User=grafana`, `ProtectHome=true` (no `~`),
  `ProtectSystem=full` (`/var/lib` writable), no capabilities, `@system-service`
  syscall filter. A git sidecar must be a separate unit.
- `settings` is freeform INI; arbitrary sections like
  `secrets_manager.encryption.secret_key.v1` and `feature_toggles.<name> =
  true` work.

### gcx / grafanactl / grizzly (CLI pull/push)

- grizzly: archived (`grafana-cold-storage/grizzly`), removed from docs.
- grafanactl v0.1.10: README says deprecated, archive 2026-06-01, replaced by
  `gcx`. Grafana 13 docs list "gcx (recommended), grafanactl (deprecated)".
- grafanactl semantics (gcx inherits the model): uses only the k8s-style
  `/apis/...` endpoints; `pull` writes `<path>/<Kind>/<uid>.json` manifests
  with server fields stripped (keeps `grafana.app/folder`, `grafana.app/
  message`, `grafana.app/saved-from-ui` annotations; the last one churns on
  Grafana upgrades); Go `encoding/json` escapes `<>&` as `<` etc.
  (stable, noisy in PromQL); `push` is GET-then-PUT last-writer-wins, folders
  first, missing folders NOT created, and by default stamps
  `grafana.app/managedBy: kubectl` which makes the UI treat the dashboard as
  managed/read-only (`push --omit-manager-fields` to avoid). No diff / watch
  / sync. Token via env or config file only (no `_FILE`).
- Preferred-version trap: pulling `dashboards` without pinning returns v2
  manifests because the server prefers v2. Pin `dashboards.v1.dashboard.
  grafana.app` or set `[grafana-apiserver] preferred_api_version =
  dashboard.grafana.app/v1`.
- gcx v1.6.0 (`~/dev/gcx`, nixpkgs `pkgs/by-name/gc/gcx`, builds `cmd/gcx`,
  no patches): same push/pull engine as grafanactl, plus:
  - `pull` writes `<path>/<plural>.<version>.<group>/<uid>.json` (API
    version in the dir name). Unversioned pull uses the server's preferred
    version (v2 for us); pin with `dashboards.v1beta1.dashboard.grafana.app`.
    Push never converts; each file is sent under its own `apiVersion`.
  - Resources managed by another tool (Git Sync, file provisioning,
    terraform) are skipped on pull/push unless `--include-managed`. Push
    stamps `managedBy: kubectl`, `managerId: gcx`, `managerAllowsEdits:
    true` unless `--omit-manager-fields`. Last-writer-wins, no prune, no
    diff/sync/watch, no git or Git Sync commands (but generic
    `gcx resources get|pull|push repositories.provisioning.grafana.app`
    should work through discovery; untested).
  - `gcx dashboards get|list|create|update|delete --api-version`.
  - `gcx dev serve`: local preview that proxies the real Grafana frontend +
    datasource queries and serves dashboards from local files; UI Save
    writes back to the source file. Preview only, no push.
  - `claude-plugin/`: a Claude Code plugin with 24 Grafana skills + a
    `grafana-debugger` agent, compiled into the binary
    (`gcx agent skills install --all --dir <dir>`). No MCP config.
  - Pitfalls: OS keychain on by default and fails closed on headless
    machines (`GCX_KEYCHAIN=off`); token only via env/config
    (`GRAFANA_TOKEN="$(cat file)"`); `GRAFANA_ORG_ID=1` required on OSS;
    telemetry on by default (`GCX_TELEMETRY=disabled` / `DO_NOT_TRACK=1`);
    JSON output `\u003c`-escapes `<>&` (use `-o yaml`); several docs
    pages disagree with the code (trust the code).

### mcp-grafana v2.1.1

`~/dev/mcp-grafana`, nixpkgs `pkgs/by-name/mc/mcp-grafana` (binary
`mcp-grafana`, `CGO_ENABLED=0`, no patches).

- Transport: stdio default (also sse, streamable-http). Env: `GRAFANA_URL`,
  `GRAFANA_SERVICE_ACCOUNT_TOKEN` or `..._TOKEN_FILE` (re-read per request),
  `GRAFANA_ORG_ID`. Flags: `--enabled-tools=<categories>` (allowlist,
  replaces defaults), `--disable-<category>`, `--disable-write` (read-only),
  `--disable-query`, `--instructions-append "<text>"`,
  `--usage-stats=disabled` (default ON, posts to stats.grafana.org).
- Tools we care about: `search_dashboards`, `get_dashboard_summary`,
  `get_dashboard_property` (JSONPath read), `get_dashboard_panel_queries`,
  `get_dashboard_by_uid`, `list_dashboard_versions`, `update_dashboard`
  (full JSON create/overwrite, or `uid` + JSONPath `operations[]`
  replace/add/remove; `folderUid`, `message`), `create_folder`,
  `list_datasources`, `query_prometheus{,_histogram}`,
  `list_prometheus_metric_names/metadata/label_names/label_values`,
  `generate_deeplink`, `grafana_api_request` (generic REST escape hatch),
  `list_provisioning_repositories`, `validate_provisioning_file`.
- VictoriaMetrics: `tools/prom_backend.go` switches on datasource type and has
  a native `victoriametrics-metrics-datasource` backend (instant/range via
  `/api/ds/query`; metadata via the plugin resource proxy, with a fallback).
  No second prometheus-type datasource needed. `run_panel_query` (off by
  default) does not support VM.
- Dashboard reads use `/apis/dashboard.grafana.app/v1beta1/...` on Grafana
  >= 12; v1 writes use legacy `POST /api/dashboards/db`; v2 via k8s API.
  Guards against v1-over-v2 and v2-over-v1 overwrites. Tool description
  steers new dashboards to v2 unless told otherwise (`--instructions-append`).
- Permissions: a service account with role Editor covers dashboards/folders
  read+write and datasource query. OSS can't assign fine-grained RBAC to
  service accounts, so Editor (rw) or Viewer (ro).
- Redirect guard: `GRAFANA_URL` must be the final URL
  (`https://grafana.phlip9.com`), no http->https hop.
- Context-size strategy (README): summary -> property reads -> patch ops;
  avoid `get_dashboard_by_uid` on big dashboards (Node Exporter Full is
  237 KiB).

### grafana-llm-app (skip)

- App plugin `grafana-llm-app` (Go backend `gpx_llm`): proxies LLM calls
  (openai, azure, anthropic via OpenAI-compat endpoint, custom
  OpenAI-compatible URL) for other plugins/features via `@grafana/llm`.
- In core OSS 13.2.4 the only consumer is
  `public/app/features/dashboard/components/GenAI/`: four "Auto-generate"
  buttons (dashboard/panel title/description). No chat UI, no agent.
- Embeds mcp-grafana 2.0.2 served at
  `/api/plugins/grafana-llm-app/resources/mcp/grafana`, running as a shared
  plugin service account that needs `externalServiceAccounts` (preview, off)
  + `[auth] managed_service_accounts_enabled`. Older than upstream and worse
  scoped than our own SA.
- Grafana Assistant (`grafana-assistant-app`) needs a Grafana Cloud stack as
  backend; `dashboardMutationAPI` is allowlisted to it only.
- Not in nixpkgs; packaging via `grafanaPlugins.grafanaPlugin` is ~15 lines,
  but no NixOS option for app-plugin provisioning (`provision.plugins`).
- Verdict: low value for us. Revisit only if OSS grows a first-party chat.

## Options

### A. Git Sync, `github` type, dotfiles repo

Grafana commits directly to `phlip9/dotfiles` at `nixos/sauna/grafana/`
(branch `master` or a dedicated branch), pulls via Grafana-registered
webhook (unauthenticated HMAC-verified endpoint, passes through nginx as-is)
with 60s polling as fallback.

- (+) Native UX: save drawer with branch + commit message, optional PR flow,
  pull from git within a minute, agent writes become commits. Zero sidecar.
- (-) GitHub PAT lives in Grafana's sqlite DB; must override the public
  default secrets-manager key. PAT needs Contents RW on dotfiles.
- (-) Repository resource not file-provisionable: one-time UI/API setup or a
  NixOS oneshot that PUTs it (idempotent) after grafana starts.
- (-) Grafana-authored commits land on the dotfiles branch; if `master`, they
  interleave with normal commits (single-user repo, probably fine). Branch
  workflow + PR avoids that at the cost of a merge step per change.
- (-) Public Grafana + GitHub coupling; outage of either stalls sync.

### B. Git Sync, `local` type + git sidecar unit

Grafana reads/writes manifests in `/var/lib/grafana/repo/` (a git worktree
of dotfiles, sparse-checked-out or a dedicated branch). A systemd unit
(`grafana-repo-sync`, user `grafana` or a group-shared dir) runs on a timer
and/or path trigger: `git add -A && git commit -m "grafana: ..." && git push`
plus `git pull --rebase` before each cycle. Deploy key (ssh) via sops.

- (+) No PAT in Grafana's DB, no secrets-manager key concern, ssh deploy key
  scoped to one repo. Works for any git host.
- (+) UI/agent saves hit disk immediately; Grafana re-scans on interval.
- (-) Write workflow only (no branch/PR UX). Commit messages come from the
  sidecar, not the save drawer (Grafana's `comment` arg is ignored for
  local). Commit author is the machine.
- (-) Our own sync unit to write and test (NixOS VM test). Conflict handling
  is `git pull --rebase` + overwrite; acceptable for a single editor.
- (-) `permitted_provisioning_paths` must include the dir; Grafana unit needs
  write access (dir owned by `grafana`).

### C. No Git Sync: DB-managed + `gcx` pull/push via `just`

Dashboards stay normal DB dashboards (freely editable). `just grafana-pull`
runs `gcx resources pull` into `nixos/sauna/grafana/` and you commit;
`just grafana-push` restores. Optionally a timer on sauna pushes a snapshot
to a backup branch.

- (+) Simplest, zero server-side config, no managed/read-only semantics.
- (-) Sync is manual and easy to forget; git is a backup, not the source of
  truth; provisioning-on-deploy is still a separate step; `gcx push`
  defaults need care (`--omit-manager-fields`, version pinning).

### D. Classic file provisioning from the nix store (rejected)

Every deploy that touches the dashboards dir re-imports and wipes UI edits.
Only acceptable for truly static vendored dashboards (e.g. community
dashboards we never edit), and then still in combination with A/B/C.

## Recommendation

Option A as the primary mechanism, with C's `gcx pull` as the one-time
migration + periodic sanity backup, and mcp-grafana for the agent. Rationale:
it is the only path where UI edits, agent edits, and git stay in sync
automatically with no custom glue, and it is first-party OSS in 13.x. If the
PAT-in-DB or Grafana-commits-on-master tradeoffs are unacceptable, B is the
fallback with the same on-disk format (switching A<->B later is just a
different Repository spec; files are identical).

Proposed layout in dotfiles:

```
nixos/sauna/grafana/            # Git Sync path
  _folder.json?                 # only if we want a wrapper folder
  node-exporter-full.json       # dashboard.grafana.app/v1 manifests
  nginx.json
  postgres-overview.json
  victoriametrics.json          # dashboard.grafana.app/v2 (already v2)
```

Agent setup (phlipdesk): `mcp-grafana` from nixpkgs, stdio, service account
`claude-code` (Editor) token in `~/.config/grafana/sa-token` (mode 0600, not
in git), `.mcp.json` in dotfiles with `GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE`,
`--usage-stats=disabled`, `--enabled-tools=search,dashboard,folder,
datasource,prometheus,navigation,user,provisioning`, and
`--instructions-append` telling it the datasource is
`{type: victoriametrics-metrics-datasource, uid: victoriametrics}` and which
dashboard schema to use.

## Decisions (2026-10-26)

1. Mechanism: A, Git Sync `github` type. Webhook enabled (2026-10-29,
   initially disabled to keep the PAT narrow): Grafana registers and owns
   the hook itself and rejects deliveries for hooks it didn't register, so
   the manual-hook + sops-secret pattern of `github-webhook.nix` doesn't
   apply. Cost: PAT additionally needs Webhooks RW + Administration R.
2. Target: `phlip9/dotfiles`, branch `master`, path `nixos/sauna/grafana/`.
   Write workflow (direct commit) + branch workflow (PR) both enabled.
3. Schema: mixed. Server keeps v2 preferred. Imported community dashboards
   stay v1 manifests; the VM dashboard stays v2; new dashboards v2.
4. Sync target: `folderless` (top level, subdirs become folders).
5. Agent: Claude Code on phlipdesk via mcp-grafana (stdio), service account
   token file outside git. grafana-llm-app not used.
6. Secrets manager key: add `secret_key.v2` provider from sops and switch
   `[secrets_manager] encryption_provider` to it (documented rotation path;
   keeps the default `v1` provider readable for any existing data keys).

## Open decisions (resolved above, kept for context)

1. Repo type: A (`github`, PAT) vs B (`local` + sidecar). Default: A.
2. Branch + path: commit straight to `master` at `nixos/sauna/grafana/`, or
   a dedicated branch (e.g. `grafana`) merged manually. Default: `master`,
   write workflow, PR workflow also enabled for larger changes.
3. Wrapper folder (`target: folder`, folder named after the repo) vs
   `folderless` (dashboards at top level). Default: `folderless` (matches
   today's layout).
4. Dashboard schema policy: keep v2 as the server's preferred version (new
   dashboards are v2; export/pull default to v2) or pin
   `[grafana-apiserver] preferred_api_version = dashboard.grafana.app/v1`
   and keep community dashboards in classic v1 JSON. Default: leave v2
   preferred; keep imported community dashboards as v1 manifests; tell the
   agent to patch v1 dashboards in place and create new ones as v2.
5. Where the agent runs: phlipdesk (`.mcp.json` in dotfiles, token file
   outside git) vs also on sauna (localhost URL). Default: phlipdesk.
6. Webhook: disabled (poll 60s) vs nginx-exposed unauthenticated webhook
   path with HMAC. Default: disabled.

## Verify before implementing (live, cheap)

- Create a throwaway `local` or `github` Repository in the UI with
  `target: folderless`, import one dashboard, save from UI, confirm commit /
  file content and the `apiVersion` written.
- `update_dashboard` via mcp-grafana on a synced dashboard produces a commit
  (code says yes; untested).
- `gcx resources pull dashboards.v1.dashboard.grafana.app` output vs Git
  Sync file format (should be the same manifest shape).
- Node Exporter Full (237 KiB) under the 5 MiB `max_file_size`: fine.
- Override `[secrets_manager.encryption.secret_key.v1] secret_key` BEFORE
  creating a github Repository (changing it later orphans stored secrets).

## Status (2026-10-26)

Implemented on branch `agent/research-oss-grafana-dashboard-sync`:

- `o11y.nix`: `grafana.secretsManagerKeyFile` (secret_key.v2 provider),
  `grafana.gitSync.*` options + `grafana-git-sync-setup.service` oneshot
  (idempotent POST/PUT of the Repository resource, token via credentials).
- `nixos/tests/o11y.nix`: secrets-manager provider check; `local` repo
  round trip (file -> dashboard, k8s PUT -> file), idempotent setup.
- `nixos/sauna/grafana/*.json`: the 4 live dashboards exported as manifests.
- `.mcp.json` + `.claude/settings.json` + `home/{phlipdesk,sauna}.nix`:
  mcp-grafana (unstable 2.1.1) for Claude Code, read tools pre-allowed.
- Runbooks in `README.md` (secrets, PAT, migration, service account).

Agent workflow that falls out of the write caveat above: read/query/verify
via mcp-grafana; edit existing dashboards as files in git (push, Grafana
pulls); create new dashboards either as files or via `update_dashboard`
(v2). Follow-up: teach mcp-grafana to use the k8s API for v1 writes when
the dashboard is repo-managed (upstream change), or add a thin `files` API
write tool.

## Implementation sketch (pre-implementation, kept for context)

1. `o11y.nix`: add `settings.secrets_manager.encryption."secret_key.v1".
   secret_key = "$__file{...}"` (new sops secret), `settings.provisioning.*`
   if needed, `settings.paths.permitted_provisioning_paths` (B only).
2. New sops secret: GitHub fine-grained PAT (A) or ssh deploy key (B).
3. Repository resource bootstrap: NixOS oneshot `grafana-gitsync-setup`
   (curl PUT, idempotent) or a documented one-time UI step.
4. Migrate: `gcx resources pull` the 4 dashboards into
   `nixos/sauna/grafana/` as v1/v2 manifests, delete originals in Grafana,
   let sync import them.
5. mcp-grafana: `home/mods/` entry or `.mcp.json` + `just grafana-sa-token`
   runbook; `doc/o11y/README.md` runbook updates.
6. NixOS VM test `nixos/tests/o11y.nix`: `local` repository round-trip
   (file -> dashboard -> UI save -> file).
