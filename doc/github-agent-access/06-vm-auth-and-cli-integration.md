# VM Auth and CLI Integration

This doc specifies Linux/NixOS runtime auth for automated agent credentials.

## 1. Service Model

Component: `github-agent-authd` (`systemd` socket-activated service)

Implementation target:
- Go service in `pkgs/github-agent-authd`
- packaged via Nix, similar conventions as `pkgs/github-webhook`

Primary files:
- pkgs/github-agent-authd/default.nix
- pkgs/github-agent-authd/main.go
- pkgs/github-agent-authd/main_test.go
- nixos/mods/github-agent-authd.nix
- nixos/tests/github-agent-authd.nix

Responsibilities:
- load app private key + app ID
- resolve installation for target repo on demand
- mint/cache short-lived installation tokens
- serve local token API over Unix domain socket

Runtime model:
- `github-agent-authd.socket` listens on local Unix socket
- `github-agent-authd.service` starts only when a client connects
- service performs no GitHub calls until a token request arrives
- service shutdown after 30min idle timeout

## 2. Local Access Control

Socket policy:
- path: `/run/github-agent-authd/socket`
- mode: `0660`
- owner: root (socket unit)
- group: `github-agent`

Access model:
- only local users in `github-agent` group can query tokens
- example: add `phlip9` to `github-agent` group in VM NixOS config

Systemd socket requirements:
- `ListenStream=/run/github-agent-authd/socket`
- `SocketMode=0660`
- `SocketGroup=github-agent`
- `DirectoryMode=0755`

## 3. Service Config example

```env
GITHUB_API_BASE="https://api.github.com"
APP_ID="1234567"
APP_KEY_PATH="%d/app-key" # via LoadCredential=app-key:/path/to/key.pem
INSTALLATION_CACHE_TTL=5m
IDLE_SHUTDOWN_TIMEOUT=30m
```

Notes:
- installation resolution always uses auto-discovery:
  `GET /repos/{owner}/{repo}/installation`
- static installation map is optional test-only behavior, not default contract

## 4. Token API Protocol

Transport:
- HTTP over Unix domain socket

Endpoints:
- `GET /repos/OWNER/REPO/token`
- `GET /healthz`

`/repos/OWNER/REPO/token` response:

```json
{
  "token": "<redacted>",
  "expires_at": "2026-02-15T13:45:00Z",
}
```

This protocol is simple enough for shell clients via `curl --unix-socket` and
`jq`, so a thin bash client is acceptable.

## 5. Client Binary Contract

User-facing token command:

```bash
github-agent-token --repo OWNER/REPO
```

Behavior:
- reads token from `github-agent-authd` Unix socket API
- no direct GitHub API calls from this client
- prints token to stdout only on success
- prints diagnostics to stderr on failure

Exit codes:
- `0`: success
- `10`: unknown repo/installation
- `11`: app auth failure (JWT/key)
- `12`: general failure (catch-all: invalid args, socket errors, GitHub API
  failures, unexpected daemon errors)
- `13`: policy denied (HTTP 403 from daemon)

## 6. Token Lifecycle

- installation token TTL: 1 hour (platform default)
- refresh when remaining TTL < 10 minutes
- app JWT validity: <= 10 minutes

Caching:
- in-memory cache only; no persistent token file
- token cache keyed by installation ID + repo scope
- installation cache (`OWNER/REPO -> installation_id`) with TTL 5 minutes
  (caches both postitive and negative `OWNER/REPO -> none`).
- on mint/auth errors indicating stale install state, invalidate cache entry
  and retry discovery once

Token scope:
- authd always mints downscoped installation tokens for requested repo only
  (`repositories` field in the access token request body)

## 7. `git` Integration

Credential helper name:
- `github-agent-git-credential-helper`

Behavior:
- parse git credential protocol input
- extract `OWNER/REPO` from `path` field, or fall back to parsing the `url`
  field if `path` is absent
- call `github-agent-token --repo OWNER/REPO`
- return `username=x-access-token`, `password=<token>`

Non-configured repo behavior:
- try auto-discovery through service
- if repo has no app installation, helper should fail cleanly and allow git
  fallback behavior (including anonymous clone for public repos)

Home Manager config:

```nix
programs.git.settings.credential."https://github.com" = {
  helper = "${lib.getExe phlipPkgs.github-agent-git-credential-helper}";
  useHttpPath = true;
};
```

## 8. `gh` Integration

`gh` wrapper should fetch token per invocation and export `GH_TOKEN`.

Packaging:
- nix package in `pkgs/github-agent-gh`
- integrated via `home/mods/github-agent.nix` as `programs.gh.package`
  (replaces default `gh`), with `gitCredentialHelper.enable = false`

Wrapper behavior:
- derive repo in this order:
  1. explicit `--repo`/`-R` argument
  2. current git remote (upstream tracking branch, then origin, then first
     remote)
  3. fail with actionable error (no implicit repo default)
- normalize `--repo`/`-R` to `OWNER/REPO` for token resolution
- fetch token via `github-agent-token --repo OWNER/REPO`
- if caller passed `--repo`/`-R`: forward normalized `--repo OWNER/REPO`
  to `gh` (not all subcommands accept `--repo`, e.g. `gh help`)
- if repo was auto-detected from git: exec `gh` without `--repo` and let
  `gh` do its own remote detection
- `GH_TOKEN` exported in both cases

## 9. systemd Runtime and Hardening

Service unit requirements:
- `DynamicUser=true` (prefer dynamic service identity)
- `LoadCredential=` for app private key material
- socket activation via paired `.socket` unit

Hardening settings:
- `LockPersonality=true`
- `MemoryDenyWriteExecute=true`
- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectControlGroups=true`
- `ProtectHome=read-only`
- `ProtectKernelModules=true`
- `ProtectKernelTunables=true`
- `ProtectSystem=strict`
- `RestrictSUIDSGID=true`

## 10. Observability

Structured log fields:
- repo
- installation_id
- cache_outcome (`positive_hit`, `negative_hit`, `miss`)
- latency_ms
- kind (`unknown_installation`, `app_auth_failure`,
  `github_api_failure`, `stale_installation`, `invalid_request`, `internal`)

Never log:
- raw token
- private key bytes
- JWT payload

## 11. Failure Handling

### Expired token mid-flight

- current git/gh call may fail
- next invocation gets refreshed token automatically

### App key rotated

- service reload/restart picks up new key
- old key mint attempts fail closed

### Repo not installed

- token endpoint returns `unknown repo/installation` error
- helper/wrapper surfaces actionable error

### Install/uninstall churn

- cached `installation_id` may go stale after install scope changes
- authd invalidates stale entry on GitHub auth/mint failure and re-discovers

## Sources

- App JWT and token auth:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app>
- Installation auth and installation discovery:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Git with app tokens (`x-access-token`):
  <https://docs.github.com/en/apps/creating-github-apps/writing-code-for-a-github-app/building-ci-checks-with-a-github-app>
- `gh` auth environment variables:
  <https://cli.github.com/manual/gh_help_environment>
