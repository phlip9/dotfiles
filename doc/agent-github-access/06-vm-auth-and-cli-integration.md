# VM Auth and CLI Integration

This doc specifies the Linux VM runtime for automated credentials.

## 1. Service Model

Component: `agent-github-authd` (systemd service)

Responsibilities:
- load long-lived app private key and app ID
- resolve installation ID for target repo
- mint and cache short-lived installation tokens
- expose local credential interfaces for `git` and `gh`

Recommended deployment:
- system service for single-agent VM host
- optional user service for per-user isolation

## 2. Secret Inputs

Long-lived inputs:
- `githubAppId`
- `githubAppPrivateKey` (PEM)
- optional static repo->installation map

Storage requirements:
- manage with sops/sops-nix
- file mode `0400` where practical
- service user must be least privilege

## 3. Broker Contract

CLI contract:

```bash
agent-gh-token --repo OWNER/REPO --format raw
agent-gh-token --repo OWNER/REPO --format env
agent-gh-token --repo OWNER/REPO --format json
```

Output contract:
- `raw`: token only
- `env`: `GH_TOKEN=<token>`
- `json`:
  - `token`
  - `expires_at`
  - `repo`

Exit codes:
- `0`: success
- `10`: unknown repo/installation
- `11`: app auth failure (JWT/key)
- `12`: GitHub API failure
- `13`: policy denied

## 4. Token Lifecycle

- Token TTL target: 1 hour (platform default).
- Refresh threshold: renew when remaining TTL < 10 minutes.
- JWT lifetime for app auth: <= 10 minutes.

Caching:
- in-memory cache keyed by `(installation_id, permissions, repository_set)`
- optional short-lived runtime cache file under `/run`

## 5. `git` Integration

Use a credential helper that requests token per host+repo.

Example helper behavior:
- parse git credential protocol input (`protocol`, `host`, `path`)
- map `path` -> `OWNER/REPO`
- call `agent-gh-token --repo OWNER/REPO --format raw`
- return:
  - `username=x-access-token`
  - `password=<token>`

Suggested git config:

```ini
[credential "https://github.com"]
    helper = !agent-git-credential-helper
    useHttpPath = true
```

## 6. `gh` Integration

`gh` should get token per invocation through `GH_TOKEN`.

Wrapper contract:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo="${AGENT_GH_DEFAULT_REPO:-$(git remote get-url origin | sed -E 's#.*github.com[:/]([^/]+/[^/.]+)(\\.git)?#\\1#')}"
export GH_TOKEN="$(agent-gh-token --repo "$repo" --format raw)"
exec /run/current-system/sw/bin/gh "$@"
```

Notes:
- Keep behavior identical to standard `gh` CLI arguments.
- Avoid writing token to disk or shell history.

## 7. systemd Hardening

Minimum hardening settings:
- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=strict`
- `ProtectHome=read-only` (or tighter)
- `ProtectKernelTunables=true`
- `ProtectControlGroups=true`
- `RestrictSUIDSGID=true`
- `MemoryDenyWriteExecute=true` (if runtime allows)

Runtime dirs:
- `RuntimeDirectory=agent-github-authd`
- Unix socket mode `0600`

## 8. Observability

Structured log fields:
- repo
- installation_id
- token_expires_at
- cache_hit
- latency_ms
- error_class

Never log:
- raw token
- private key bytes
- JWT payload

## 9. Failure Handling

### Expired token mid-flight

- Git operation fails with auth error.
- Next helper call fetches fresh token automatically.

### App key rotated

- service picks up new secret on restart/reload.
- old key mint attempts fail closed.

### Repo not installed

- broker returns `unknown repo/installation` with non-zero exit.

## Sources

- App JWT and token auth:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app>
- Installation auth and git usage:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Git with app tokens (`x-access-token`):
  <https://docs.github.com/en/apps/creating-github-apps/writing-code-for-a-github-app/building-ci-checks-with-a-github-app>
- `gh` environment auth variables:
  <https://cli.github.com/manual/gh_help_environment>
