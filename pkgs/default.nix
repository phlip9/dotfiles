{ pkgs }:
let
  callPackage = pkgs.callPackage;
in
{
  # aider - AI developer agent cli
  aider-chat = pkgs.aider-chat;

  # cargo-release - release a Rust package
  cargo-release = pkgs.cargo-release;

  # claude-code - Anthropic claude code CLI
  claude-code = callPackage ./claude-code { };

  # codex - OpenAI codex CLI
  codex = callPackage ./codex.nix { };

  # dist - build and distribute binary releases
  dist = pkgs.cargo-dist;

  # profiler.firefox.org but local
  firefox-profiler = callPackage ./firefox-profiler.nix { };

  # restore fs mtimes from git
  git-restore-mtime = callPackage ./git-restore-mtime.nix { };

  # block/goose - AI developer agent cli
  goose-cli = callPackage ./goose-cli.nix { };

  # ctz/graviola - devshell for graviola development
  graviola-tools = callPackage ./graviola-tools.nix { };

  # phlip9/imgen - OpenAI API image generator cli
  imgen = callPackage ./imgen.nix { };

  # go-acme/lego - patched Let's Encrypt ACME client
  lego = callPackage ./lego.nix { };

  # LosslessCut - extremely simple linear video cutting
  lossless-cut = callPackage ./lossless-cut.nix { };

  # Claude modelcontextprotocol server for filesystem access
  mcp-server-filesystem = callPackage ./mcp-server-filesystem/default.nix { };

  # MOMW Tools Pack pre-built unstable
  momw-tools-pack = callPackage ./momw-tools-pack.nix { };

  # nixfmt - standard nix formatter
  # TODO(phlip9): change to `pkgs.nixfmt` after release-25.11
  nixfmt = pkgs.nixfmt-rfc-style;

  # OpenMW pre-built unstable
  openmw = callPackage ./openmw.nix { };

  # sampling profiler written in Rust, with native firefox-profiler integration
  samply = callPackage ./samply.nix { };
}
