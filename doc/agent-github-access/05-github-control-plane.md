# GitHub Control Plane

This doc defines GitHub-side app and ruleset configuration.

## 1. Shared App Configuration

### 1.1 App installation scope

MUST use `Only select repositories` installs.

Rationale:
- limits blast radius if app key or VM is compromised.

### 1.2 App repository permissions

Required for normal unprivileged engineer-like workflows plus agent writes:
- `Contents`: `Read and write` (git fetch/push)
- `Pull requests`: `Read and write` (PR create/edit)
- `Issues`: `Read` (issue context)
- `Actions`: `Read` (workflow status/log visibility)
- `Checks`: `Read` (check run/check suite visibility)
- `Commit statuses`: `Read` (legacy status context)
- `Metadata`: `Read` (default)

Do not grant unrelated write scopes (repo admin, issues write, actions write,
secrets, webhooks) unless a separate documented workflow needs them.

### 1.3 Events

No webhook subscription is required for core `git` + `gh` usage.

## 2. Branch Contract

Agents MUST create only:
- `agent/<engineer>/<task>`

Examples:
- `agent/phlip9/fix-nvim-lsp-crash`
- `agent/alice/update-rust-1.88`

## 3. Strict Mode (org repos)

Strict mode is required by default on organization repos.

### RS2. Non-agent deny for app identity (required)

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
- app cannot create/update/delete non-`agent/**` refs.
- app can still write `agent/**` because those refs are excluded from this deny
  ruleset.

### RS1. Critical branch PR policy (recommended, not required)

Name: `critical-branches-pr-only`

Target refs:
- include: `refs/heads/master`, `refs/heads/release/**`

Rules (minimum):
- `pull_request`
- `non_fast_forward`
- `deletion`

Purpose:
- governance protection for all actors, not only the app identity.

### Why no separate RS3 allow rule by default

We do not need an explicit allow ruleset for `agent/**` in this model.

Reason:
- RS2 denies only non-`agent/**` refs.
- app already has `Contents: Read and write` permission.
- refs not denied by rulesets are writable by normal permission checks.

Add explicit `allow-agent-namespace` only if your repo policy later adopts a
broader deny-by-default pattern that also blocks `agent/**`.

## 4. Reduced Mode (personal repo fallback)

Use only if strict actor controls cannot be fully enforced.

Minimum controls:
- protect `master` and `release/**` with PR-required policy.
- keep app install scope limited to selected repositories.
- enforce local branch naming and pre-push checks on VM.
- perform periodic manual audit of app-attributed ref updates.

Residual risk:
- app may retain broader write ability than strict mode guarantees.
- this risk MUST be recorded in the repo risk register.

## 5. API-First Provisioning (simple POST flow)

Use operator `gh api` commands with stable ruleset names.

### 5.1 Create rulesets

Endpoint:
- `POST /repos/{owner}/{repo}/rulesets`

Base payload (RS2):

```json
{
  "name": "deny-non-agent-updates",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~ALL"],
      "exclude": ["refs/heads/agent/**"]
    }
  },
  "bypass_actors": [
    {
      "actor_id": 0,
      "actor_type": "OrganizationAdmin",
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

If name collisions occur, operator can delete old ruleset and re-POST baseline
payload.

### 5.2 Verify effective rules

Use:
- `GET /repos/{owner}/{repo}/rules/branches/{branch}`

Check at least:
- `master`
- `release/1.2.3`
- `agent/phlip9/smoke`
- `feature/non-agent`

## Sources

- About rulesets:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- Rulesets REST API:
  <https://docs.github.com/en/rest/repos/rules>
- Rules for a branch API:
  <https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>
