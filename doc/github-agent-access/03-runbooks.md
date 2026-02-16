# Runbooks

## 1. Bootstrap: Create Shared GitHub App

One-time setup. Open: <https://github.com/settings/apps/new>

| Page field | Value |
|---|---|
| `GitHub App name` | `phlip9-github-agent` |
| `Description` | `Autonomous coding agent identity that can only make PRs to agent/** branches` |
| `Homepage URL` | `https://github.com/phlip9/dotfiles/blob/master/doc/github-agent-access/01-overview.md` |
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

Post-create:
1. Record `App ID` and app slug from app settings.
2. Generate and download private key (`.pem`).
3. Store key in sops secrets for VM deployment.

## 2. Onboard New Repository

Preconditions:
- shared app exists
- operator has repo admin rights

Steps:
1. Install app on repo (`Only select repositories`).
2. Apply baseline rulesets:

```bash
just/github-agent-post-repo-ruleset.sh OWNER/REPO
```

The script creates `deny-non-agent-updates` in `disabled` enforcement
with empty bypass actors. It prints the settings URL — add bypass
actors (org admin / maintainer team) and set enforcement to `active`.

If a ruleset with the same intent already exists, delete the stale one
and re-POST.

3. Run push/PR smoke tests from agent VM.

For personal repos where strict mode is unavailable: apply
critical-branch PR policy for `master`/`release/**`, mark as `reduced`
mode, run periodic manual audit.

## 3. Onboard New Agent VM

Preconditions:
- VM has access to required sops age key

Steps:
1. Place app private key secret in host secret file.
2. Deploy `github-agent-authd` systemd socket + service units.
3. Configure `git` credential helper.
4. Configure `gh` wrapper integration.
5. Run smoke tests:

```bash
# token retrieval
github-agent-token --repo OWNER/REPO

# git write to allowed namespace
git checkout -b agent/phlip9/smoke-$(date +%s)
git push -u origin HEAD

# gh PR workflow
gh pr create --repo OWNER/REPO --fill
```

## 4. Rotate GitHub App Private Key

Goal: rotate without agent downtime beyond token refresh window.

Steps:
1. Generate new key in GitHub App settings.
2. Add new key to secrets management.
3. Redeploy/reload `github-agent-authd` on VMs.
4. Validate token mint with new key.
5. Revoke old key in app settings.
6. Run push/PR smoke tests.

Rollback: if failures occur before old key revocation, revert VM secret
to old key and restart service.

## 5. Revoke Compromised VM

Immediate:
1. Disable VM network access if possible.
2. Remove app installation from impacted repos (or suspend app).
3. Rotate app private key.
4. Redeploy key to trusted VMs only.
5. Review recent app-attributed ref updates and PR activity.

Post-incident:
- Regenerate host credentials.
- Rebuild VM from known-good image.
- Re-run onboarding tests before restoring access.

## 6. Repair Policy Mismatch

Causes: manual UI edits, repo transfer, ownership changes.

Steps:
1. Rerun `just/github-agent-post-repo-ruleset.sh OWNER/REPO`.
2. Re-add bypass actors and enable enforcement.
3. Re-run effective-rule checks for `master`, `release/**`,
   `agent/**`, and a non-agent branch.

## 7. Break-Glass Manual Intervention

Use only for urgent production remediation.

Allowed actions:
- Human admin bypass on protected branch.
- Temporary ruleset disable (`disabled`) with ticket/incident
  reference.

Required follow-up:
1. Revert temporary bypass/disable.
2. Re-POST baseline rulesets from versioned payloads.
3. Attach audit trail (who/when/why).

## 8. Decommission Repository

Steps:
1. Remove repo from app installation scope.
2. Delete/disable repo-specific rulesets if no longer needed.
3. Verify token mint fails for repo (stale cache self-heals).

Verification:

```bash
github-agent-token --repo OWNER/REPO
# expected: non-zero exit (unknown repo/installation)
```

## 9. Rollback Rulesets

1. Disable or delete newly posted ruleset.
2. Re-POST prior known-good payload.
3. Re-run verification checks.

## Sources

- Registering GitHub Apps:
  <https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app>
- App installation auth and token behavior:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Rulesets REST API:
  <https://docs.github.com/en/rest/repos/rules>
- Rules for a branch API:
  <https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>
