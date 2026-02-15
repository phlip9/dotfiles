# Provisioning and Automation

This doc defines API-first provisioning and reconciliation.

## 1. Inputs

Required inputs:
- `OWNER` (org or user)
- `REPO`
- `APP_ID`
- `APP_SLUG`
- optional `MAINTAINERS_TEAM_SLUG` (strict org mode)

Operator auth requirements:
- human admin token with repository/ruleset admin rights
- `gh` CLI authenticated as operator account

## 2. One-Time Bootstrap

### 2.1 Create shared GitHub App

Primary path:
- Create app once in GitHub UI.
- Set permissions from `05-github-control-plane.md`.
- Generate private key.

Rationale:
- App bootstrap API flow is less ergonomic than repository policy automation.

### 2.2 Install app on selected repositories

MUST choose `Only select repositories` and approve target repos.

## 3. Repo Onboarding (API-first)

### 3.1 Preflight checks

```bash
OWNER="my-org"
REPO="my-repo"

# repo reachable
gh api "/repos/$OWNER/$REPO" >/dev/null

# rulesets API available for repo
gh api "/repos/$OWNER/$REPO/rulesets" >/dev/null
```

### 3.2 Discover actor IDs

```bash
# App actor id is app id for Integration bypass actors.
APP_ID="1234567"

# Optional: team actor id for human bypass path (org strict mode).
TEAM_ID="$(gh api "/orgs/$OWNER/teams/maintainers" --jq '.id')"
```

### 3.3 Apply rulesets idempotently

Pattern:
1. `GET /repos/{owner}/{repo}/rulesets`
2. map by `name`
3. `POST` missing rulesets
4. `PATCH` existing rulesets to desired payload

Example list rulesets:

```bash
gh api "/repos/$OWNER/$REPO/rulesets" --jq '.[] | {id,name,enforcement,target}'
```

Example create:

```bash
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "/repos/$OWNER/$REPO/rulesets" \
  --input rs3-allow-agent-namespace.json
```

## 4. Desired State Payload Files

Keep versioned JSON payload templates:
- `rs1-critical-branches-pr-only.json`
- `rs2-deny-non-agent-updates.json`
- `rs3-allow-agent-namespace.json`

Templatize with environment substitution for actor IDs.

## 5. Reconciliation Job

Schedule periodic job (e.g., hourly):
1. enumerate managed repos
2. fetch rulesets
3. diff against desired JSON (normalized)
4. fail on drift and emit actionable diff
5. optionally auto-remediate with `PATCH`

## 6. Effective Policy Verification

Verify branch outcomes, not only config objects.

```bash
for branch in master release/1.0 agent/phlip9/smoke feature/foo; do
  gh api "/repos/$OWNER/$REPO/rules/branches/$branch" \
    --jq '{branch:"'$branch'", rules:[.[]?.type]}'
done
```

## 7. Reduced Mode Automation

For personal repos where strict mode is unavailable:
- apply critical branch protection ruleset only
- mark repo mode in inventory as `reduced`
- enable extra monitoring and periodic push-attribution audits

## 8. Rollback

Rollback strategy:
1. disable newly applied ruleset (`enforcement=disabled`)
2. restore last-known-good payload
3. re-run verification suite

## 9. Deliverables

Automation package SHOULD include:
- one idempotent onboarding command
- one reconciliation command
- one verification command
- JSON templates under version control

## Sources

- Rulesets REST API:
  <https://docs.github.com/en/rest/repos/rules>
- Rules for a branch API:
  <https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>
