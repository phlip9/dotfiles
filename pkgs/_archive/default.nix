# archived nix packages
{ pkgs }:
let
  callPackage = pkgs.callPackage;

  fix =
    f:
    let
      x = f x;
    in
    x;
in

fix (phlipPkgs: {
  _type = "pkgs";

  # claude-agent-acp - ACP adapter for Anthropic claude code CLI
  claude-agent-acp = callPackage ./claude-agent-acp.nix {
    inherit (phlipPkgs) claude-code;
  };

  # codex-acp - ACP adapter for OpenAI codex CLI
  codex-acp = callPackage ./codex-acp.nix {
    inherit (phlipPkgs) codex;
  };

  # profiler.firefox.org but local
  firefox-profiler = callPackage ./firefox-profiler.nix { };

  # ctz/graviola - devshell for graviola development
  graviola-tools = callPackage ./graviola-tools.nix { };

  # MOMW Tools Pack pre-built unstable
  # TODO(phlip9): GitLab CI artifacts expired, need to update URL
  momw-tools-pack = callPackage ./momw-tools-pack.nix { };
})
