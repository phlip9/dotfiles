# github-agent-git-credential-helper: git credential helper that fetches
# repo-scoped GitHub App installation tokens via github-agent-token.
{
  lib,
  runCommandWith,
  stdenvNoCC,
  github-agent-token,
}:

runCommandWith
  rec {
    name = "github-agent-git-credential-helper";
    stdenv = stdenvNoCC;
    runLocal = true;
    derivationArgs = {
      githubAgentToken = lib.getExe github-agent-token;
      meta = {
        mainProgram = name;
      };
    };
  }
  ''
    mkdir -p $out/bin
    substituteAll \
      ${./github-agent-git-credential-helper.sh} \
      $out/bin/github-agent-git-credential-helper
    chmod +x $out/bin/github-agent-git-credential-helper
  ''
