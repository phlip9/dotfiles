# Research and Platform Facts

This doc records platform facts that constrain the design. Each fact includes a
source and a design implication.

## F1. App installation tokens are short-lived

Fact:
- Installation access tokens expire after 1 hour.

Implication:
- VM runtime needs automatic refresh and retry logic.
- Long-running commands must tolerate token rollover.

Source:
- <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>

## F2. Git over HTTPS works with installation tokens

Fact:
- GitHub supports `git clone`/`git fetch` over HTTPS with installation tokens,
  using username `x-access-token` and token as password.

Implication:
- We can keep normal HTTPS `git` flows and avoid SSH deploy keys.
- A custom git credential helper can inject ephemeral app tokens.

Source:
- <https://docs.github.com/en/apps/creating-github-apps/writing-code-for-a-github-app/building-ci-checks-with-a-github-app>

## F3. Installation tokens can be scoped at mint time

Fact:
- Token mint requests can limit repository access and downscope permissions via
  `repositories` / `repository_ids` and `permissions` body fields.

Implication:
- Broker can request minimum needed repo + permission scope per operation.

Source:
- <https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>

## F4. App JWT lifetime is bounded

Fact:
- App JWTs must be signed with RS256 and are limited to a short validity window
  (`exp` no more than 10 minutes in the future).

Implication:
- Broker should mint JWTs on demand, not store them.

Source:
- <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app>

## F5. `gh` supports token auth via env

Fact:
- `gh` honors `GH_TOKEN` (and `GITHUB_TOKEN`) for github.com auth.
- `GH_TOKEN` is the preferred variable for github.com usage.

Implication:
- Wrap `gh` to export a freshly minted token per invocation.

Sources:
- <https://cli.github.com/manual/gh_help_environment>
- <https://cli.github.com/manual/gh_auth_login>

## F6. Rulesets support layered policy

Fact:
- Multiple rulesets can apply to the same branch/tag simultaneously.
- Rulesets can target branches, tags, and push events.

Implication:
- We can layer: non-agent deny constraints (RS2) + optional critical-branch
  PR policy (RS1), without a default explicit allow ruleset.

Source:
- <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>

## F7. Ruleset bypass supports app actors

Fact:
- Rulesets support bypass actor types including `Integration` (GitHub App),
  along with org admin/repo role/team actor types.

Implication:
- Strict mode can explicitly allow the app only where intended.

Source:
- <https://docs.github.com/en/rest/repos/rules>

## F8. Ruleset API supports enforcement states

Fact:
- Ruleset API models enforcement states `active`, `evaluate`, `disabled`.

Implication:
- Rollout can use staged policy promotion where available.

Source:
- <https://docs.github.com/en/rest/repos/rules>

## F9. Branch rules introspection returns active rules

Fact:
- `GET /repos/{owner}/{repo}/rules/branches/{branch}` returns all rules active
  on a branch.

Implication:
- Drift checks can validate effective branch policy, not only raw config.

Source:
- <https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch>

## F10. Rulesets availability varies by plan/repo type

Fact:
- Rulesets availability differs by repository visibility and GitHub plan.

Implication:
- We need dual-mode docs (strict and reduced) and explicit gating checks in
  onboarding automation.

Source:
- <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
