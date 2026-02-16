# Implementation

## 1. GitHub App Configuration

### App permissions (least privilege)

- `Contents`: `Read and write` (git fetch/push)
- `Pull requests`: `Read and write` (PR create/edit)
- `Issues`: `Read` (issue context)
- `Actions`: `Read` (workflow status/log visibility)
- `Checks`: `Read` (check run/check suite visibility)
- `Commit statuses`: `Read` (legacy status context)
- `Metadata`: `Read` (default)

No webhook subscription needed. No unrelated write scopes.

### App installation scope

`Only select repositories`. Limits blast radius if app key or VM is
compromised.

### Branch contract

Agents create only: `agent/<engineer>/<task>`

Examples: `agent/phlip9/fix-nvim-lsp-crash`,
`agent/alice/update-rust-1.88`

### Rulesets

**`deny-non-agent-updates`** (required for strict mode):
- target: `~ALL` excluding `refs/heads/agent/**`
- rules: `creation`, `update`, `deletion`
- bypass actors: human governance only (org admin / maintainer team)
- effect: app cannot write non-`agent/**` refs; `agent/**` excluded
  from deny, so normal permissions apply

**`critical-branches-pr-only`** (recommended, not required):
- target: `refs/heads/master`, `refs/heads/release/**`
- rules: `pull_request`, `non_fast_forward`, `deletion`
- governance protection for all actors, not only the app

No explicit allow ruleset needed for `agent/**` — RS2 excludes those
refs, and the app has `Contents: Read and write`.

### Reduced mode (personal repo fallback)

When strict actor controls are unavailable:
- protect `master` and `release/**` with PR-required policy
- keep app install scope limited to selected repositories
- enforce local branch naming and pre-push checks on VM
- periodic manual audit of app-attributed ref updates

## 2. Token Broker (`github-agent-authd`)

Go service in `pkgs/github-agent-authd`. Systemd socket-activated.

Primary files:
- `pkgs/github-agent-authd/default.nix`
- `pkgs/github-agent-authd/main.go`
- `pkgs/github-agent-authd/main_test.go`
- `nixos/mods/github-agent-authd.nix`
- `nixos/tests/github-agent-authd.nix`

### Socket and access control

- path: `/run/github-agent-authd/socket`
- mode: `0660`, group: `github-agent`
- only local users in `github-agent` group can query tokens

### Environment variables

```env
GITHUB_API_BASE="https://api.github.com"
APP_ID="1234567"
APP_KEY_PATH="%d/app-key"  # via LoadCredential=app-key:/path/to/key.pem
INSTALLATION_CACHE_TTL=5m
IDLE_SHUTDOWN_TIMEOUT=30m
```

### Token API

HTTP over Unix domain socket.

- `GET /healthz` — readiness probe
- `GET /repos/OWNER/REPO/token` — repo-scoped installation token

Response:

```json
{
  "token": "<redacted>",
  "expires_at": "2026-02-15T13:45:00Z"
}
```

### Token lifecycle

- Installation token TTL: 1 hour (platform default).
- Refresh when remaining TTL < 10 minutes.
- App JWT validity: <= 10 minutes, minted on demand.
- Tokens always downscoped to requested repo only (`repositories`
  field in access token request body).

### Caching

- In-memory only; no persistent token file.
- Token cache keyed by `{installation_id, OWNER/REPO}`.
- Installation cache (`OWNER/REPO -> installation_id`) with
  configurable TTL (default 5m). Caches both positive and negative
  (`OWNER/REPO -> none`) lookups.
- On mint/auth errors indicating stale install state, invalidate cache
  entry and retry discovery once.

### Idle shutdown

Socket activation: `github-agent-authd.socket` listens; service starts
on first client connection, shuts down after 30min idle (configurable).

### systemd hardening

`DynamicUser=true`, `LoadCredential=` for app private key, plus
standard sandboxing (`ProtectSystem=strict`, `NoNewPrivileges=true`,
etc). See `nixos/mods/github-agent-authd.nix` for full list.

Logs must never contain raw tokens, private key bytes, or JWT
payloads.

### Failure handling

- **Expired token mid-flight**: current call may fail; next invocation
  gets refreshed token automatically.
- **App key rotated**: service reload/restart picks up new key.
- **Repo not installed**: returns `unknown repo/installation` error.
- **Install/uninstall churn**: cached `installation_id` may go stale;
  authd invalidates stale entry on mint failure and re-discovers.

## 3. Token Client (`github-agent-token`)

Thin bash client in `pkgs/github-agent-token`.

```bash
github-agent-token --repo OWNER/REPO
```

- Reads token from `github-agent-authd` via `curl --unix-socket` + `jq`
- No direct GitHub API calls
- Prints token to stdout on success, diagnostics to stderr on failure

Exit codes:
- `0`: success
- `10`: unknown repo/installation
- `11`: app auth failure (JWT/key)
- `12`: general failure (catch-all: invalid args, socket errors,
  GitHub API failures, unexpected daemon errors)
- `13`: policy denied (HTTP 403 from daemon)

## 4. Git Credential Helper

`github-agent-git-credential-helper` in
`pkgs/github-agent-git-credential-helper`.

- Parses git credential protocol input
- Extracts `OWNER/REPO` from `path` field, or falls back to parsing
  the `url` field if `path` is absent
- Calls `github-agent-token --repo OWNER/REPO`
- Returns `username=x-access-token`, `password=<token>`
- On unknown repo (exit 10): silent exit 0 so git falls back to other
  credential helpers (including anonymous clone for public repos)

Home Manager config (`home/mods/github-agent.nix`):

```nix
programs.git.settings.credential."https://github.com" = {
  helper = "${lib.getExe phlipPkgs.github-agent-git-credential-helper}";
  useHttpPath = true;
};
```

## 5. `gh` Wrapper

`github-agent-gh` in `pkgs/github-agent-gh`. Integrated via
`home/mods/github-agent.nix` as `programs.gh.package` (replaces
default `gh`), with `gitCredentialHelper.enable = false`.

Repo resolution order:
1. Explicit `--repo`/`-R` argument
2. Current git remote (upstream tracking branch → origin → first
   remote)
3. Fail with actionable error

Token injection:
- Normalizes repo to `OWNER/REPO` for token resolution
- Fetches token via `github-agent-token --repo OWNER/REPO`
- If caller passed `--repo`/`-R`: forwards normalized `--repo` to `gh`
- If repo was auto-detected from git: execs `gh` without `--repo`
  (not all subcommands accept it, e.g. `gh help`)
- `GH_TOKEN` exported in both cases

## Sources

- App JWT and token auth:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app>
- Installation auth and discovery:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Git with app tokens (`x-access-token`):
  <https://docs.github.com/en/apps/creating-github-apps/writing-code-for-a-github-app/building-ci-checks-with-a-github-app>
- `gh` auth environment variables:
  <https://cli.github.com/manual/gh_help_environment>
- About rulesets:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- Rulesets REST API:
  <https://docs.github.com/en/rest/repos/rules>
