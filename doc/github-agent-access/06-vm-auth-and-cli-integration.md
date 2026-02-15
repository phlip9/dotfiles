# VM Auth and CLI Integration

This doc specifies Linux/NixOS runtime auth for automated agent credentials.

## 1. Service Model

Component: `github-agent-authd` (`systemd` socket-activated service)

Implementation target:
- Go service in `pkgs/github-agent-authd`
- packaged via Nix, similar conventions as `pkgs/github-webhook`

Responsibilities:
- load app private key + app ID
- resolve installation for target repo on demand
- mint/cache short-lived installation tokens
- serve local token API over Unix domain socket

Runtime model:
- `github-agent-authd.socket` listens on local Unix socket
- `github-agent-authd.service` starts only when a client connects
- service performs no GitHub calls until a token request arrives

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
- `DirectoryMode=0750`

## 3. Service Config example

```env
GITHUB_API_BASE="https://api.github.com"
APP_ID="1234567"
APP_KEY_PATH=/run/XXX/github-app-key.pem # via LoadCredential
INSTALLATION_CACHE_TTL=5m
INSTALLATION_NEGATIVE_CACHE_TTL=5m
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
- `12`: GitHub API failure
- `13`: policy denied

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
  (`repositories` / `repository_ids`)

## 7. `git` Integration

Credential helper name:
- `github-agent-git-credential-helper`

Behavior:
- parse git credential protocol input
- map `path` to `OWNER/REPO`
- call `github-agent-token --repo OWNER/REPO`
- return `username=x-access-token`, `password=<token>`

Non-configured repo behavior:
- try auto-discovery through service
- if repo has no app installation, helper should fail cleanly and allow git
  fallback behavior (including anonymous clone for public repos)

Home Manager config:

```nix
programs.git.settings.credential."https://github.com" = {
  helper = "${phlipPkgs.github-agent-git-credential-helper}";
  useHttpPath = true;
};
```

## 8. `gh` Integration

`gh` wrapper should fetch token per invocation and export `GH_TOKEN`.

Packaging:
- nix package in `pkgs/` (for example `pkgs/github-agent-gh`)
- add wrapper package to `home/omnara1.nix` `home.packages`

Wrapper behavior:
- derive repo in this order:
  1. explicit `--repo`
  2. current git remote
  3. fail with actionable error (no implicit repo default)
- fetch token via `github-agent-token --repo OWNER/REPO`
- exec real `gh` with unchanged args

## 9. systemd Runtime and Hardening

Service unit requirements:
- `DynamicUser=true` (prefer dynamic service identity)
- `LoadCredential=` for app private key material
- socket activation via paired `.socket` unit

Hardening settings:
- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=strict`
- `ProtectHome=read-only` (or tighter)
- `ProtectKernelTunables=true`
- `ProtectControlGroups=true`
- `RestrictSUIDSGID=true`
- `MemoryDenyWriteExecute=true` (if runtime allows)

## 10. Observability

Structured log fields:
- repo
- installation_id
- token_expires_at
- cache_outcome (`positive_hit`, `negative_hit`, `miss`)
- latency_ms
- error_class

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
