# github-agent-token: fetch a repo-scoped installation token from the local
# github-agent-authd unix-socket API.
{
  lib,
  curl,
  jq,
  stdenvNoCC,
  runCommandWith,
}:

runCommandWith
  rec {
    name = "github-agent-token";
    stdenv = stdenvNoCC;
    runLocal = true;
    derivationArgs = {
      curl = lib.getExe curl;
      jq = lib.getExe jq;
      meta = {
        mainProgram = name;
      };
    };
  }
  ''
    mkdir -p $out/bin
    substituteAll ${./github-agent-token.sh} $out/bin/github-agent-token
    chmod +x $out/bin/github-agent-token
  ''
