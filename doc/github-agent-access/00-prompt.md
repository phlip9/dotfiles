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

---

Here's some comments and feedback on our design doc:

doc/agent-github-access/04-architecture.md:

* (Ruleset drift) adding a ruleset-drift-check job is probably overkill for now.
  As far as I can tell, we're not hard-coding any branch names other than
  `agent/**`.

doc/agent-github-access/05-github-control-plane.md:

* (1.2 App repository permissions) Just to make sure we're on the same page,
  agents also need to be able to _Read_ issues, actions status and logs, and
  other basic things like a normal but unprivileged engineer.

* (3.RS1. + 3.RS2. + 3.RS3.) Why do we need both the "Critical branch
  protection" and the "Deny agent updates"? At first glance, it seems like we
  just need RS2 to protect non-`agent/**` branches? Likewise, why do we need to
  give explicit allow create/update/delete in RS3.? Is it because we're not
  giving branch R/W in the App permissions?

doc/agent-github-access/06-vm-auth-and-cli-integration.md:

* (`agent-github-authd`): First, let's rename this to `github-agent-authd`.

  To flesh this out a bit, to ensure only certain local
  UNIX users can access the service's local unix domain socket, I imagine we'll
  want to make the socket access 0660 and add e.g. the `phlip9` user to the
  UNIX group?

  I imagine we'll configure the service with a single json config file for all
  the repos the app is connected to? Or can it auto-discover that somehow?

  What does the protocol look like for the client to read the current token?
  Is this simple enough that we can just cook up a quick bash script for the
  client?

  We'll probably want to write this service in Go, place it in
  `pkgs/github-agent-authd`, and package it with nix. I imagine it should look
  similar to our other Go service in `pkgs/github-webhook`.

* (Broker contract): we can rename this to `github-agent-token`

* (`git` Integration): Here's another requirement to consider, does this `git`
  credential helper integration support the agent cloning other repos? Agents
  should be able to clone any other repos that aren't explicitly configured.

  Let's also rename the git credential helper to
  `github-agent-git-credential-helper`.

  We'll configure this using home-manager using something like:

  ```nix
  programs.git.settings.credential."https://github.com" = {
    helper = "${phlipPkgs.github-agent-git-credential-helper}";
    useHttpPath = true;
  };
  ```

* (`gh` Integration): quickly remark that we'll nix package this `gh` wrapper
  in pkgs/ and add it to `home/omnara1.nix`'s home-manager config.

doc/agent-github-access/07-provisioning-and-automation.md:

* Fetch/diff/reconcile is too complicated. Let's just POST with consistent
  ruleset names if possible.
