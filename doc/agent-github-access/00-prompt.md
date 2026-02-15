Clarify requirements, research, and write a fully fleshed out series of design
documents in doc/agent-github-access/.

Context:

* Engineers each have their own isolated VMs or machines that run autonomous
  coding agents. These VMs can have engineer-private credentials as they are
  not shared between engineers. These VMs only run NixOS + Linux. We don't have
  to worry about other supporing anything else.

* Agents eventually need to submit their changes as PRs to our repos. However,
  they need limited and controlled access to the repo. Agents absolutely should
  not be able to push to `master` without going through a PR approval flow.

Problem: Right now, we're using separate agent GitHub accounts per engineer. This
approach is simplest for limiting access but doubles our per-head cost for
private repos and other services.

Proposal: use a GitHub App agent identity with limited permissions and per-repo
branch protection rulesets.

Requirements:

* Agents must only be able to write or push to `agent/**` branches. They
  absolutely cannot touch `master`, `release/**`, or any other branches.

* Agents must be able to interact with `git` and `gh` CLIs in a relatively
  normal manner.

* Once setup, the agent VM should be able to manage its credentials is fully
  automated and hands-off way.

* Adding new systemd system services or user services is OK.

* VMs can have long-lived credentials.
