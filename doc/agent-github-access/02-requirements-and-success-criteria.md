# Requirements and Success Criteria

## Scope

Applies to autonomous coding agents running on isolated Linux/NixOS VMs with
engineer-private credentials.

## Functional Requirements

### R1. Agent Branch Write Scope

Agents MUST only be able to create/update/delete branches under `agent/**`.

Agents MUST NOT be able to update:
- `master`
- `release/**`
- any non-`agent/**` branch

### R2. PR-Based Integration

Agent-submitted changes MUST be integrated via pull requests.

Direct pushes by the agent identity to protected integration branches MUST be
blocked by repository policy.

### R3. Normal CLI Workflow

Agents MUST be able to use:
- `git` over HTTPS for fetch/push
- `gh` for common PR operations (`pr create`, `pr view`, `pr edit`)

with minimal workflow differences versus standard CLI use.

### R4. Hands-Off Credential Lifecycle

After initial bootstrap, VM credential management MUST be automated.

The runtime path MUST mint short-lived installation access tokens from a
long-lived GitHub App private key without human intervention.

### R5. Linux + systemd Compatibility

Design MUST run on Linux/NixOS and MAY add systemd system/user services.

### R6. Least Privilege

GitHub App permissions MUST be minimal for required actions and explicitly
documented.

### R7. Auditability

The design MUST include onboarding and change-time verification of app
installation scope and effective branch policy state.

Continuous reconciliation/drift automation is OPTIONAL for now.

## Security Requirements

### S1. Long-Lived Secret Boundaries

Long-lived credentials on VMs MUST be limited to:
- app private key (or equivalent secret material)
- app ID and installation mapping metadata

Short-lived tokens MUST NOT be persisted longer than needed.

### S2. Secret Exposure Controls

Token broker interfaces MUST be local-only (Unix socket/localhost) with
process/user-level access controls.

### S3. Revocation

Compromised VM access MUST be revocable by:
- disabling/removing app installation from target repos
- rotating app private key

## Operational Requirements

### O1. Onboarding

Adding a new repo MUST be scriptable and idempotent.

### O2. Rotation

App key rotation MUST be documented as a low-downtime runbook.

### O3. Multi-Repo Support

One shared app MUST support selected installations across multiple repos.

## Enforcement Modes

### Strict Mode (default for org repos)

Strict mode MUST satisfy R1 directly via GitHub-side policy.

### Reduced Mode (personal-repo fallback)

If strict actor-level controls are not available for a personal repo, reduced
mode MAY be used, but the doc set MUST explicitly list residual risk and
compensating controls.

## Acceptance Criteria Matrix

| ID | Test | Pass Condition |
|---|---|---|
| A1 | push `agent/phlip9/test` | succeeds using app identity |
| A2 | push `master` | rejected by server policy |
| A3 | push `release/1.2.3` | rejected by server policy |
| A4 | push `feature/foo` | rejected by server policy in strict mode |
| A5 | `gh pr create` from `agent/**` | succeeds with brokered token |
| A6 | token expiry rollover | no manual intervention; commands keep working |
| A7 | uninstall app from repo | subsequent push attempts fail |
| A8 | ruleset mismatch introduced | verification checklist detects mismatch |

## Sources

- Branch and ruleset model:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- GitHub App installation auth:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
