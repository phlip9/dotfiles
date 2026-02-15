# github-agent-gh: gh wrapper that injects repo-scoped GitHub App tokens from
# github-agent-authd via github-agent-token.
{
  lib,
  gh,
  git,
  runCommandWith,
  stdenvNoCC,
  github-agent-token,
}:

runCommandWith
  rec {
    name = "github-agent-gh";
    stdenv = stdenvNoCC;
    runLocal = true;
    derivationArgs = {
      gh = lib.getExe gh;
      git = lib.getExe git;
      githubAgentToken = lib.getExe github-agent-token;
      meta = {
        mainProgram = name;
      };
    };
  }
  ''
    mkdir -p $out/bin
    substituteAll ${./github-agent-gh.sh} $out/bin/github-agent-gh
    chmod +x $out/bin/github-agent-gh
  ''
