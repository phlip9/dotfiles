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
  {
    name = "github-agent-gh";
    stdenv = stdenvNoCC;
    runLocal = true;
    derivationArgs = {
      gh = lib.getExe gh;
      git = lib.getExe git;
      githubAgentToken = lib.getExe github-agent-token;
      meta = {
        mainProgram = "gh";
      };
    };
  }
  ''
    mkdir -p $out/bin
    substituteAll ${./gh.sh} $out/bin/gh
    chmod +x $out/bin/gh
  ''
