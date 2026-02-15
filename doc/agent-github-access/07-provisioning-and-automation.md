# Provisioning and Automation

This doc defines simple API-first onboarding.

## 1. Inputs

Required inputs:
- `OWNER` (org or user)
- `REPO`
- `APP_ID`
- optional `MAINTAINERS_TEAM_SLUG` (strict org mode)

Operator auth requirements:
- admin-capable operator account in `gh`

## 2. One-Time Bootstrap

### 2.1 Create shared GitHub App

Primary path:
- create app in GitHub UI
- set permissions from `05-github-control-plane.md`
- generate private key

### 2.2 Install app on selected repositories

MUST choose `Only select repositories` and approve target repos.

## 3. Repo Onboarding (POST baseline)

### 3.1 Preflight checks

```bash
OWNER="my-org"
REPO="my-repo"

# repo reachable
gh api "/repos/$OWNER/$REPO" >/dev/null

# rulesets API reachable
gh api "/repos/$OWNER/$REPO/rulesets" >/dev/null
```

### 3.2 Apply baseline rulesets

Use stable names and POST baseline payloads.

Strict org mode baseline:
- `deny-non-agent-updates` (required)
- `critical-branches-pr-only` (recommended, not required)

Example:

```bash
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "/repos/$OWNER/$REPO/rulesets" \
  --input rs2-deny-non-agent-updates.json

# optional recommended RS1
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "/repos/$OWNER/$REPO/rulesets" \
  --input rs1-critical-branches-pr-only.json
```

If a ruleset with the same intent already exists and blocks POST by policy,
manually delete stale one and re-POST the baseline payload.

### 3.3 Verify effective behavior

```bash
for branch in master release/1.0 agent/phlip9/smoke feature/foo; do
  gh api "/repos/$OWNER/$REPO/rules/branches/$branch" \
    --jq '{branch:"'$branch'", rules:[.[]?.type]}'
done
```

## 4. Payload Files

Keep versioned JSON payload templates:
- `rs2-deny-non-agent-updates.json` (required strict mode)
- `rs1-critical-branches-pr-only.json` (recommended, not required)

## 5. Reduced Mode Automation

For personal repos where strict mode is unavailable:
- apply critical branch PR policy for `master` and `release/**`
- mark repo mode as `reduced`
- run periodic manual audit checks

## 6. Rollback

Rollback strategy:
1. disable or delete newly posted ruleset
2. re-POST prior known-good payload
3. re-run verification checks

## 7. Deliverables

Automation package SHOULD include:
- one onboarding command/script (`post-baseline-rulesets`)
- one verification command/script (`verify-branch-rules`)
- versioned JSON payload templates

## Sources

- Rulesets REST API:
  <https://docs.github.com/en/rest/repos/rules>
- Rules for a branch API:
  <https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>
