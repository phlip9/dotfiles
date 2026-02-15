# Architecture

## Topology

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
│  agent-github-authd          │
│  (systemd service)           │
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

## Components

### 1. Shared GitHub App (control-plane identity)

Responsibilities:
- Represents all agent writes.
- Installed only on selected repositories.
- Holds minimal repo permissions.

### 2. Repository Rulesets

Responsibilities:
- Enforce branch write boundaries.
- Prevent direct app writes to critical branches.
- Constrain app writes to `agent/**` in strict mode.

### 3. VM Token Broker (`agent-github-authd`)

Responsibilities:
- Load long-lived app private key from secret store.
- Mint short-lived installation token on demand.
- Cache tokens until refresh threshold.
- Provide local credential interface to `git`/`gh`.

### 4. CLI Integration Layer

Responsibilities:
- `git`: credential helper asks broker for token.
- `gh`: wrapper exports `GH_TOKEN` from broker.

## Trust Boundaries

### Boundary A: Long-lived secret material

Inside VM only:
- App private key
- App ID
- Repo -> installation mapping metadata

Controls:
- sops-managed secret material
- strict file/socket permissions
- systemd hardening

### Boundary B: Short-lived tokens

Characteristics:
- 1-hour TTL installation tokens
- local memory + short-lived cache file/socket only

Controls:
- never committed to disk as static config
- sanitized logs (no token output)

### Boundary C: GitHub policy state

Characteristics:
- app installation scope
- ruleset definitions

Controls:
- idempotent API-managed desired state
- periodic drift detector

## Runtime Data Flow

1. Agent runs `git push origin agent/phlip9/task-x`.
2. Git credential helper requests token from broker for `OWNER/REPO`.
3. Broker resolves installation ID and mints/refreshes installation token.
4. Helper returns:
   - `username=x-access-token`
   - `password=<installation_token>`
5. GitHub accepts push if rulesets allow branch/ref update.
6. Agent runs `gh pr create`; wrapper injects `GH_TOKEN` from broker and execs
   real `gh`.

## Failure Modes and Handling

### Token mint fails

Likely causes:
- expired/invalid app key
- app removed from repo
- wrong installation ID mapping

Handling:
- broker returns explicit error code
- caller retries with bounded backoff
- alert on repeated failures

### Ruleset drift

Likely causes:
- manual UI edits
- repo transfer or plan changes

Handling:
- reconciliation job diffs desired vs actual rulesets
- blocks new VM onboarding until corrected in strict mode

### Reduced-mode gaps (personal repos)

Likely causes:
- missing actor controls or bypass semantics for strict model

Handling:
- explicit reduced-mode declaration per repo
- compensating controls + extra audit checks

## Threat Model

### T1. Token exfiltration from process env/history

Mitigations:
- per-command token injection only
- no shell history writes of tokens
- no token logging

### T2. App private key theft from VM

Mitigations:
- restricted secret path ownership/mode
- systemd sandboxing and minimal service privileges
- key rotation runbook

### T3. Policy bypass via misconfigured rulesets

Mitigations:
- strict-mode onboarding preflight
- effective-rule introspection checks
- deny-by-default non-agent writes for app identity

### T4. Over-broad app install scope

Mitigations:
- install app with selected repositories only
- periodic installation inventory check

## Design Defaults

- One shared app identity across repos.
- Strict mode for org repos by default.
- Reduced mode only when strict controls are unavailable and explicitly accepted.

## Sources

- App install auth and token lifecycle:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Rulesets behavior and layering:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
