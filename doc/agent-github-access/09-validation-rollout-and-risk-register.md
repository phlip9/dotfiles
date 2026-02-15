# Validation, Rollout, and Risk Register

## 1. Validation Matrix

### 1.1 Functional tests

| Test ID | Scenario | Expected Result |
|---|---|---|
| V1 | app push to `agent/phlip9/test` | success |
| V2 | app push to `master` | rejected |
| V3 | app push to `release/1.2.3` | rejected |
| V4 | app push to `feature/foo` (strict mode) | rejected |
| V5 | `gh pr create` from `agent/**` | success |
| V6 | app token expires and retries | auto-refresh, command succeeds |

### 1.2 Security tests

| Test ID | Scenario | Expected Result |
|---|---|---|
| S1 | token in logs check | no token material found |
| S2 | app removed from repo install | new pushes fail |
| S3 | key rotation | old key invalid, new key works |
| S4 | ruleset bypass actor drift | detected by reconciliation |

### 1.3 Policy effectiveness tests

Branch samples per repo:
- `master`
- `release/1.2.3`
- `agent/<engineer>/smoke`
- `feature/non-agent`

Use `GET /rules/branches/{branch}` to assert active effective rules.

## 2. Rollout Plan

### Phase 0: Lab validation

- enable on one non-critical org repo
- run full validation matrix for 7 days

Exit criteria:
- 0 critical policy failures
- no manual token interventions

### Phase 1: Org pilot

- migrate 2 to 5 actively used org repos
- enforce strict mode

Exit criteria:
- >= 99.9% broker token success
- all drift alerts remediated within SLA

### Phase 2: Broad org rollout

- migrate remaining org repos in batches
- require strict mode unless exception approved

Exit criteria:
- all org repos managed by reconciliation job

### Phase 3: Personal repo handling

- attempt strict mode eligibility checks
- where unavailable, classify as reduced mode with explicit risk acceptance

Exit criteria:
- every personal repo is either strict or reduced with documented owner sign-off

## 3. SLOs and Alerts

SLO targets:
- token broker availability: 99.9%
- token mint success (non-4xx policy): 99.5%
- drift detection freshness: <= 24h

Alerts:
- repeated token mint failures (>5 in 10m)
- ruleset missing/disabled on managed repo
- app unexpectedly installed on unmanaged repo

## 4. Risk Register

### RSK-1: App private key compromise

Impact:
- attacker can mint installation tokens for installed repos.

Mitigations:
- selected-repo installs only
- key rotation runbook
- strict VM secret handling

Residual risk:
- exposure window until detection + key rotation.

### RSK-2: Ruleset drift

Impact:
- app may gain write access outside `agent/**`.

Mitigations:
- periodic reconciliation
- effective-rule verification endpoints

Residual risk:
- drift between checks.

### RSK-3: Reduced mode on personal repos

Impact:
- strict app-only branch isolation may not be fully enforceable.

Mitigations:
- protect critical branches
- local pre-push policy checks
- higher-frequency audits

Residual risk:
- non-zero chance of broader app branch writes.

### RSK-4: Over-broad app permissions

Impact:
- unauthorized API actions.

Mitigations:
- least-privilege permission baseline
- review on every permission change

Residual risk:
- human error during app reconfiguration.

## 5. Acceptance Gate

The migration is complete when:
1. all org repos pass strict mode tests;
2. app writes outside `agent/**` are blocked in strict mode;
3. all VMs run broker automation without manual token management;
4. personal repos have explicit strict/reduced classification and risk sign-off.

## Sources

- Ruleset fundamentals and layering:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- Rules API and effective branch rules endpoint:
  <https://docs.github.com/en/rest/repos/rules>
- App installation token auth:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
