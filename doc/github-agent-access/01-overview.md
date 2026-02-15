# GitHub App Agent Access Design

- status: draft design spec
- date: 2026-02-15
- scope: Linux-only autonomous agent VMs using `git` and `gh`

## Purpose

Define a production design for replacing per-engineer GitHub user identities
with one shared GitHub App identity, while constraining agent writes to
`agent/**` branches.

## Problem Summary

Current model: one GitHub user account per engineer/agent VM.

Downsides:
- Higher per-head cost for private repos and related services.
- More credential lifecycle overhead.
- Harder policy consistency across repos.

Target model: one shared GitHub App identity, installed per repo with selected
repository access, plus repository rulesets.

## Decision Summary

1. One shared GitHub App for agent writes.
2. Branch contract: `agent/<engineer>/<task>`.
3. VM auth model: local token broker daemon (systemd) with app private key and
   automated installation-token minting.
4. Provisioning model: API-first (`gh api`/REST), UI fallback only.
5. Repo scope: both org-owned and personal-owned repositories.
6. Enforcement modes:
   - strict mode: org repos with full ruleset/bypass actor controls.
   - reduced mode: personal repos when strict actor controls are unavailable.

## Non-Goals

- Windows/macOS agent support.
- Using personal access tokens as the primary auth model.
- Allowing direct app writes to protected branches (`master`, `release/**`).

## Document Index

1. `01-overview.md` (this doc)
2. `02-requirements-and-success-criteria.md`
3. `03-research-and-platform-facts.md`
4. `04-architecture.md`
5. `05-github-control-plane.md`
6. `06-vm-auth-and-cli-integration.md`
7. `07-provisioning-and-automation.md`
8. `08-operations-runbooks.md`

## Key Interface Contracts

- Branches created by agents: `refs/heads/agent/<engineer>/<task>`.
- Local token API (design contract):
  - `github-agent-token --repo OWNER/REPO`
- Git credential helper contract:
  - returns username `x-access-token` and password `<installation_token>`.
- `gh` auth contract:
  - per invocation, export `GH_TOKEN` from broker before executing `gh`.

## Defaults

- Shared app installs are repo-scoped (`Only select repositories`).
- Installation tokens are short-lived (1 hour) and auto-refreshed.
- Installation resolution uses per-repo auto-discovery with in-memory caching.
- Long-lived secret on VM is the GitHub App private key only.

## Sources

- About rulesets:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- Authenticating as a GitHub App installation:
  <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
