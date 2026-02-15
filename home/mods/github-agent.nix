# github-agent
#
# Configure `git` and `gh` so they use our local `github-agent-authd` service
# to get access tokens for certain repos.
#
# The agent will be able to open PRs for these repos, but only under `agent/**`
# branches.
{
  lib,
  phlipPkgs,
  ...
}:

{
  # Configure our git credential helper
  programs.git = {
    settings.credential."https://github.com" = {
      helper = "${lib.getExe phlipPkgs.github-agent-git-credential-helper}";
      useHttpPath = true;
    };
  };

  # Use our wrapped gh. Don't use gh's default credential helper.
  programs.gh = {
    package = phlipPkgs.github-agent-gh;
    gitCredentialHelper.enable = false;
  };

  # TODO(phlip9): remove these? not using separate agent github account anymore.
  # programs.git = {
  #   # This dev machine uses its own GitHub account.
  #   settings = {
  #     user.name = "lexe-agent (phlip9)";
  #     user.email = "admin+github.agent@lexe.app";
  #   };
  #
  #   # Auto-append co-author trailer to all commits so they show phlip9 as a
  #   # contributor. Works with `git commit -m` unlike commit.template.
  #   hooks.prepare-commit-msg = ./omnara1/prepare-commit-msg;
  # };
}
