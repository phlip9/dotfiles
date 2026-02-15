# GitHub Control Plane

This doc defines the GitHub-side policy and app configuration.

## 1. Shared App Configuration

### 1.1 App installation scope

MUST use `Only select repositories` installs.

Rationale:
- Limits blast radius of a compromised VM/app key.

### 1.2 App repository permissions

Minimum required permissions for agent workflow:
- `Contents`: `Read and write` (push/fetch via git)
- `Pull requests`: `Read and write` (create/edit PRs)
- `Metadata`: `Read` (default)

Do not grant unrelated write scopes (issues, actions, admin, etc.) unless a
specific documented workflow requires them.

### 1.3 Events

No webhook subscription is required for the core push/PR workflow in this
design.

## 2. Branch Contract

Agents MUST create only:
- `agent/<engineer>/<task>`

Examples:
- `agent/phlip9/fix-nvim-lsp-crash`
- `agent/alice/update-rust-1.88`

## 3. Strict Mode (org repos)

Strict mode is required by default on organization repositories.

### RS1. Critical branch protection

Name: `critical-branches-pr-only`

Target refs:
- include: `refs/heads/master`, `refs/heads/release/**`

Rules (minimum):
- `pull_request`
- `non_fast_forward`
- `deletion`

Bypass actors:
- humans only (org owners/admins as needed)
- MUST NOT include app integration actor

### RS2. Non-agent deny for app identity

Name: `deny-non-agent-updates`

Target refs:
- include: `~ALL`
- exclude: `refs/heads/agent/**`

Rules:
- `creation`
- `update`
- `deletion`

Bypass actors:
- human governance actors only (org admin and/or maintainer team)
- MUST NOT include app integration actor

Effect:
- App cannot create/update/delete non-agent refs.

### RS3. Agent branch allow

Name: `allow-agent-namespace`

Target refs:
- include: `refs/heads/agent/**`

Rules:
- `creation`
- `update`
- `deletion` (optional, but recommended for stale branch cleanup)

Bypass actors:
- include GitHub App integration actor (`actor_type=Integration`)
- include humans as needed for manual interventions

Effect:
- App can write only `agent/**` refs.

### 3.1 Why RS2 excludes `agent/**`

Rulesets layer on matching refs. Excluding `agent/**` from RS2 avoids
self-conflict so RS3 can grant app writes only where intended.

## 4. Reduced Mode (personal repos fallback)

Use only if strict actor controls cannot be enforced.

Minimum controls:
- Protect `master` and `release/**` with PR-required rules.
- Keep app install scope limited to selected repositories.
- Enforce local branch naming and pre-push checks on VM.
- Run frequent audit checks for app-attributed ref updates.

Residual risk:
- App may retain broader write ability than strict mode guarantees.
- This risk MUST be recorded in the repo risk register.

## 5. API-First Desired State Management

Use admin-maintained automation with `gh api`.

### 5.1 Create/update rulesets

Endpoint:
- `POST /repos/{owner}/{repo}/rulesets`
- `PATCH /repos/{owner}/{repo}/rulesets/{ruleset_id}`

Template payload (RS3, agent allow):

```json
{
  "name": "allow-agent-namespace",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/agent/**"],
      "exclude": []
    }
  },
  "bypass_actors": [
    {
      "actor_id": 1234567,
      "actor_type": "Integration",
      "bypass_mode": "always"
    }
  ],
  "rules": [
    {"type": "creation"},
    {"type": "update"},
    {"type": "deletion"}
  ]
}
```

### 5.2 Determine actor IDs

- GitHub App actor ID: app ID from app settings (`Integration.actor_id`).
- Team actor ID (optional): `GET /orgs/{org}/teams/{team_slug}`.

### 5.3 Verify effective rules

Use:
- `GET /repos/{owner}/{repo}/rules/branches/{branch}`

Examples:
- `master`
- `release/1.2.3`
- `agent/phlip9/smoke`
- `feature/non-agent`

## 6. Drift Detection Requirements

A scheduled control-plane check MUST validate:
- app is installed only on approved repos
- required rulesets exist and are `active`
- bypass actor lists match desired state
- effective rules for sample branches match expectations

## Sources

- About rulesets:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- Rulesets REST API (rules, bypass actors, enforcement):
  <https://docs.github.com/en/rest/repos/rules>
- Rules for a branch API:
  <https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>
