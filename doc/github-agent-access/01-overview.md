# GitHub App Agent Access

## Problem

One GitHub user account per engineer/agent VM. Downsides: higher per-head
cost for private repos, more credential lifecycle overhead, harder policy
consistency across repos.

## Solution

One shared GitHub App identity installed per repo with selected repository
access, plus repository rulesets constraining agent writes to `agent/**`
branches.

## Decisions

1. One shared GitHub App (`phlip9-github-agent`) for all agent writes.
2. Branch contract: `agent/<engineer>/<task>`.
3. VM auth: local token broker daemon (`github-agent-authd`) with app
   private key and automated installation-token minting.
4. Provisioning: API-first (`gh api`/REST), UI fallback only.
5. Scope: both org-owned and personal-owned repositories.
6. Enforcement modes:
   - strict: org repos with full ruleset/bypass actor controls.
   - reduced: personal repos when strict actor controls are unavailable.

## Non-Goals

- Windows/macOS agent support.
- Personal access tokens as primary auth model.
- Direct app writes to protected branches (`master`, `release/**`).

## Architecture

```text
┌──────────────────────────────┐
│ Agent VM (NixOS/Linux)       │
│                              │
│  git, gh, coding agent       │
│      │                       │
│      ▼                       │
│  credential helper/wrapper   │
│      │                       │
│      ▼                       │
│  github-agent-authd          │
│  (systemd socket + service)  │
│      │  app JWT + install    │
│      │  token mint           │
└──────┼───────────────────────┘
       │ HTTPS API
       ▼
┌──────────────────────────────┐
│ GitHub                       │
│  - shared GitHub App         │
│  - selected repo installs    │
│  - repo rulesets             │
└──────────────────────────────┘
```

### Components

1. **Shared GitHub App** — represents all agent writes. Installed only on
   selected repositories. Least-privilege permissions.

2. **Repository Rulesets** — enforce branch write boundaries. Keep app
   writes restricted to `agent/**` in strict mode. Optional PR-only
   integration on critical branches.

3. **`github-agent-authd`** — systemd socket-activated token broker.
   Loads app private key, resolves installations, mints repo-downscoped
   tokens, caches installation lookups and tokens in memory.

4. **CLI Integration** — `git` credential helper and `gh` wrapper inject
   short-lived tokens from the broker.

### Runtime Data Flow

1. Agent runs `git push origin agent/phlip9/task-x`.
2. git credential helper requests token from broker for `OWNER/REPO`.
3. Broker resolves (or cache-hits) installation and mints/refreshes a
   repo-scoped installation token.
4. Helper returns `username=x-access-token`, `password=<token>`.
5. GitHub accepts/refuses push based on ruleset policy.
6. Agent runs `gh pr create`; wrapper injects `GH_TOKEN` and execs `gh`.

## Trust Boundaries

### Long-lived secret material (VM only)

- app private key (sops-managed, `LoadCredential`)
- app ID and broker config metadata

Controls: restricted file/socket permissions, systemd hardening.

### Short-lived tokens

- 1-hour TTL installation tokens, in-memory only.
- Never committed to disk. Sanitized logs (no token output).

### GitHub policy state

- app installation scope, branch rulesets.
- Deterministic onboarding script with stable ruleset names.
- Manual verification checks after provisioning changes.

## Threat Model

**T1. Token exfiltration** — per-command injection only, no shell history
writes, no token logging.

**T2. App private key theft** — restricted secret path ownership/mode,
systemd sandboxing, key rotation runbook.

**T3. Ruleset misconfiguration** — strict-mode onboarding checks,
effective-rule branch verification, simple/stable deny ruleset.

**T4. Over-broad app install scope** — selected repositories only,
periodic installation inventory review.

## Document Index

1. `01-overview.md` — this doc
2. `02-implementation.md` — daemon, CLI tools, GitHub config
3. `03-runbooks.md` — provisioning, onboarding, operations
4. `04-appendix.md` — requirements, platform research

## Sources

- About rulesets:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- Authenticating as a GitHub App installation:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
