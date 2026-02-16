# Appendix: Requirements and Platform Research

## A. Requirements

### Functional

- **R1**: Agents can only create/update/delete branches under
  `agent/**`. Cannot touch `master`, `release/**`, or other branches.
- **R2**: Agent changes integrated via pull requests only.
- **R3**: Agents use `git` (HTTPS) and `gh` (PR ops) with minimal
  workflow differences vs standard CLI use.
- **R4**: After bootstrap, VM credential management is fully automated
  (short-lived tokens from long-lived app key).
- **R5**: Linux/NixOS + systemd.
- **R6**: GitHub App permissions are minimal and explicitly documented.
- **R7**: Onboarding and change-time verification of app installation
  scope and effective branch policy.

### Security

- **S1**: Long-lived VM credentials limited to app private key + app
  ID. Short-lived tokens not persisted.
- **S2**: Token broker interfaces local-only (Unix socket) with
  process/user-level access controls.
- **S3**: Compromised VM revocable by removing app installation or
  rotating app key.

### Operational

- **O1**: Adding a new repo is scriptable and idempotent.
- **O2**: App key rotation documented as low-downtime runbook.
- **O3**: One shared app supports selected installations across
  multiple repos.

### Enforcement Modes

- **Strict** (org repos): R1 satisfied directly via GitHub rulesets.
- **Reduced** (personal repos): explicit residual risk and
  compensating controls when strict actor controls unavailable.

### Acceptance Criteria

| ID | Test | Pass Condition |
|---|---|---|
| A1 | push `agent/phlip9/test` | succeeds using app identity |
| A2 | push `master` | rejected by server policy |
| A3 | push `release/1.2.3` | rejected by server policy |
| A4 | push `feature/foo` | rejected in strict mode |
| A5 | `gh pr create` from `agent/**` | succeeds with brokered token |
| A6 | token expiry rollover | no manual intervention |
| A7 | uninstall app from repo | subsequent push fails |
| A8 | ruleset mismatch introduced | verification detects it |

## B. Platform Facts

**F1. Installation tokens are short-lived** — 1-hour TTL. VM runtime
needs automatic refresh. Source:
<https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>

**F2. Git over HTTPS works with installation tokens** — username
`x-access-token`, token as password. Custom credential helper injects
ephemeral app tokens. Source:
<https://docs.github.com/en/apps/creating-github-apps/writing-code-for-a-github-app/building-ci-checks-with-a-github-app>

**F3. Tokens can be scoped at mint time** — `repositories` and
`permissions` body fields limit scope. Source:
<https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>

**F4. App JWT lifetime is bounded** — RS256, `exp` no more than 10
minutes in the future. Broker mints on demand. Source:
<https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app>

**F5. `gh` supports token auth via env** — `GH_TOKEN` is the preferred
variable. Source:
<https://cli.github.com/manual/gh_help_environment>

**F6. Rulesets support layered policy** — multiple rulesets apply
simultaneously. We layer: non-agent deny (RS2) + optional
critical-branch PR policy (RS1). Source:
<https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>

**F7. Ruleset bypass supports app actors** — bypass actor types include
`Integration` (GitHub App), org admin, repo role, team. Source:
<https://docs.github.com/en/rest/repos/rules>

**F8. Ruleset API supports enforcement states** — `active`, `evaluate`,
`disabled`. Enables staged rollout. Source:
<https://docs.github.com/en/rest/repos/rules>

**F9. Branch rules introspection** —
`GET /repos/{owner}/{repo}/rules/branches/{branch}` returns all active
rules. Enables drift checks. Source:
<https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>

**F10. Rulesets availability varies by plan** — differs by repo
visibility and GitHub plan. Drives dual-mode (strict/reduced) design.
Source:
<https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
