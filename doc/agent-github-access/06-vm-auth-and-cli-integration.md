# VM Auth and CLI Integration

This doc specifies Linux/NixOS runtime auth for automated agent credentials.

## 1. Service Model

Component: `github-agent-authd` (systemd service)

Implementation target:
- Go service in `pkgs/github-agent-authd`
- packaged via Nix, similar conventions as `pkgs/github-webhook`

Responsibilities:
- load app private key + app ID
- resolve installation for target repo
- mint/cache short-lived installation tokens
- serve local token API over Unix domain socket

## 2. Local Access Control

Socket policy:
- path: `/run/github-agent-authd/socket`
- mode: `0660`
- owner: service user
- group: `github-agent`

Access model:
- only local users in `github-agent` group can query tokens
- example: add `phlip9` to `github-agent` group in VM NixOS config

Systemd configuration requirements:
- `RuntimeDirectory=github-agent-authd`
- `RuntimeDirectoryMode=0750`
- socket file mode `0660`

## 3. Service Config example

```env
GITHUB_API_BASE="https://api.github.com"
APP_ID="1234567"
APP_KEY_PATH=/run/XXX/github-app-key.pem # via LoadCredential
DEFAULT_OWNER=phlip9
ALLOW_INSTALLATION_AUTO_DISCOVERY=1
```

- default to auto-discovery (`GET /repos/{owner}/{repo}/installation`).
- static installation map to support testing

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
github-agent-token --repo OWNER/REPO --format raw
github-agent-token --repo OWNER/REPO --format env
github-agent-token --repo OWNER/REPO --format json
```

Behavior:
- reads token from `github-agent-authd` Unix socket API
- no direct GitHub API calls from this client

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
- in-memory cache keyed by installation ID (+ permission scope)
- no persistent token file

## 7. `git` Integration

Credential helper name:
- `github-agent-git-credential-helper`

Behavior:
- parse git credential protocol input
- map `path` to `OWNER/REPO`
- call `github-agent-token --repo OWNER/REPO --format raw`
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
- derive repo from CLI context (`--repo`, git remote, or env default)
- fetch token via `github-agent-token`
- exec real `gh` with unchanged args

## 9. systemd Hardening

Minimum hardening settings:
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
- cache_hit
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

## Sources

- App JWT and token auth:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app>
- Installation auth and installation discovery:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Git with app tokens (`x-access-token`):
  <https://docs.github.com/en/apps/creating-github-apps/writing-code-for-a-github-app/building-ci-checks-with-a-github-app>
- `gh` auth environment variables:
  <https://cli.github.com/manual/gh_help_environment>
