# Operations Runbooks

## 1. Onboard New Repository

Preconditions:
- shared app exists
- operator has repo admin rights

Steps:
1. install app on repo with `Only select repositories`
2. apply strict or reduced mode rulesets
3. run effective policy verification
4. run push/PR smoke tests from agent VM

Verification commands:

```bash
OWNER="my-org"
REPO="my-repo"

# rulesets present
gh api "/repos/$OWNER/$REPO/rulesets" --jq '.[] | .name'

# effective rules sample
gh api "/repos/$OWNER/$REPO/rules/branches/master"
gh api "/repos/$OWNER/$REPO/rules/branches/agent/phlip9/smoke"
```

## 2. Onboard New Agent VM

Preconditions:
- VM has access to required sops age key

Steps:
1. place app private key secret in host secret file
2. deploy `agent-github-authd` systemd unit
3. configure `git` credential helper
4. configure `gh` wrapper integration
5. run smoke tests

Smoke tests:

```bash
# token retrieval
agent-gh-token --repo OWNER/REPO --format json

# git write to allowed namespace
git checkout -b agent/phlip9/smoke-$(date +%s)
git push -u origin HEAD

# gh PR workflow
gh pr create --repo OWNER/REPO --fill
```

## 3. Rotate GitHub App Private Key

Goal: rotate without agent downtime beyond token refresh window.

Steps:
1. generate new key in GitHub App settings
2. add new key to secrets management
3. redeploy/reload `agent-github-authd` on VMs
4. validate token mint with new key
5. revoke old key in app settings
6. run push/PR smoke tests

Rollback:
- if failures occur before old key revocation, revert VM secret to old key and
  restart service.

## 4. Revoke Compromised VM

Immediate actions:
1. disable VM network access if possible
2. remove app installation from impacted repos or suspend app temporarily
3. rotate app private key
4. redeploy key to trusted VMs only
5. review recent app-attributed ref updates and PR activity

Post-incident actions:
- regenerate host credentials
- rebuild VM from known-good image
- re-run onboarding tests before restoring access

## 5. Break-Glass Manual Intervention

Use only for urgent production remediation.

Allowed actions:
- human admin bypass on protected branch
- temporary ruleset disable (`disabled`) with ticket/incident reference

Required follow-up:
1. revert temporary bypass/disable
2. reconcile back to desired state
3. attach audit trail (who/when/why)

## 6. Decommission Repository from Agent Access

Steps:
1. remove repo from app installation scope
2. delete/disable repo-specific rulesets if no longer needed
3. remove repo from broker installation mapping
4. verify token mint fails for repo

Verification:

```bash
agent-gh-token --repo OWNER/REPO --format raw
# expected: non-zero exit (unknown repo/installation)
```

## 7. Scheduled Maintenance Checklist

Weekly:
- run ruleset drift reconciliation
- sample effective branch rule checks

Monthly:
- verify app installation inventory
- review reduced-mode repos and remediation options

Quarterly:
- rotate app private key
- run incident-response tabletop exercise

## Sources

- App installation auth and token behavior:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Rulesets REST API:
  <https://docs.github.com/en/rest/repos/rules>
