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
│  github-agent-authd          │
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
- Holds least-privilege repo permissions for read + agent write workflows.

### 2. Repository Rulesets

Responsibilities:
- Enforce branch write boundaries for the app identity.
- Keep app writes restricted to `agent/**` in strict mode.
- Optionally enforce PR-only integration flow on critical branches.

### 3. VM Token Broker (`github-agent-authd`)

Responsibilities:
- Load long-lived app private key from secret store.
- Mint short-lived installation token on demand.
- Cache tokens until refresh threshold.
- Provide local credential interface to `git`/`gh` clients.

### 4. CLI Integration Layer

Responsibilities:
- `git`: credential helper asks broker for token.
- `gh`: wrapper exports `GH_TOKEN` from broker.

## Trust Boundaries

### Boundary A: Long-lived secret material

Inside VM only:
- app private key
- app ID
- optional static defaults for owner/repo behavior

Controls:
- sops-managed secret material
- strict file/socket permissions
- systemd hardening

### Boundary B: Short-lived tokens

Characteristics:
- 1-hour TTL installation tokens
- local memory + short-lived runtime transport only

Controls:
- never committed to disk as static config
- sanitized logs (no token output)

### Boundary C: GitHub policy state

Characteristics:
- app installation scope
- branch rulesets for strict/reduced mode

Controls:
- deterministic onboarding script with stable ruleset names
- manual verification checks after provisioning changes

## Runtime Data Flow

1. Agent runs `git push origin agent/phlip9/task-x`.
2. git credential helper requests token for `OWNER/REPO` from broker.
3. Broker resolves installation and mints/refreshes installation token.
4. Helper returns:
   - `username=x-access-token`
   - `password=<installation_token>`
5. GitHub accepts/refuses push based on ruleset policy.
6. Agent runs `gh pr create`; wrapper injects `GH_TOKEN` and execs real `gh`.

## Failure Modes and Handling

### Token mint fails

Likely causes:
- expired/invalid app key
- app removed from repo
- wrong repo installation discovery behavior

Handling:
- broker returns explicit error code
- caller retries with bounded backoff
- operator validates app install + key

### Policy mismatch

Likely causes:
- manual UI edits
- repo transfer or ownership changes

Handling:
- rerun onboarding POST flow to reapply named rulesets
- run effective-rule checks for `master`, `release/**`, `agent/**`

### Reduced-mode gaps (personal repos)

Likely causes:
- strict actor controls unavailable

Handling:
- explicit reduced-mode declaration per repo
- compensating controls + periodic manual audit

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
- strict-mode onboarding checks
- effective-rule branch verification
- keep deny-non-agent ruleset simple and stable

### T4. Over-broad app install scope

Mitigations:
- install app with selected repositories only
- periodic installation inventory review

## Design Defaults

- One shared app identity across repos.
- Strict mode for org repos by default.
- Reduced mode only when strict controls are unavailable and explicitly accepted.

## Sources

- App install auth and token lifecycle:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Rulesets behavior and layering:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
