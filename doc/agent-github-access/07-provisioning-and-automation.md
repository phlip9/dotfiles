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

Open:
- <https://github.com/settings/apps/new>

Set exactly these values:

| Page field | Value |
|---|---|
| `GitHub App name` | `phlip9-github-agent` |
| `Description` | `Autonomous coding agent identity for PR-based repo updates` |
| `Homepage URL` | `https://github.com/phlip9` |
| `Callback URL` | leave blank |
| `Expire user authorization tokens` | checked |
| `Request user authorization (OAuth) during installation` | unchecked |
| `Setup URL` | leave blank |
| `Redirect on update` | unchecked |
| `Webhook` / `Active` | unchecked |
| `Webhook URL` | leave blank |
| `Webhook secret` | leave blank |
| `Where can this GitHub App be installed?` | `Any account` |

Repository permissions (set exactly):
- `Actions`: `Read-only`
- `Checks`: `Read-only`
- `Commit statuses`: `Read-only`
- `Contents`: `Read and write`
- `Issues`: `Read-only`
- `Metadata`: `Read-only`
- `Pull requests`: `Read and write`
- all other repository permissions: `No access`

Account permissions:
- all account permissions: `No access`

Subscribe to events:
- none (webhook is disabled)

Then click `Create GitHub App`.

Post-create actions:
1. record `App ID` and app slug from app settings
2. generate and download private key (`.pem`)
3. store key in sops secrets for VM deployment

### 2.2 Install app on selected repositories

From app settings, install app with:
- repository access: `Only select repositories`
- select each target repo explicitly

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

- Registering GitHub Apps:
  <https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app>
- Rulesets REST API:
  <https://docs.github.com/en/rest/repos/rules>
- Rules for a branch API:
  <https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>
