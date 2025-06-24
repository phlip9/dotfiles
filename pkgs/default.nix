{
  pkgs,
  pkgsUnstable,
}: let
  callPackage = pkgs.callPackage;
in {
  # aider - AI developer agent cli
  aider-chat = pkgsUnstable.aider-chat;

  # cargo-release - release a Rust package
  cargo-release = pkgsUnstable.cargo-release;

  # claude-code - Anthropic claude code CLI
  claude-code = callPackage ./claude-code {};

  # dist - build and distribute binary releases
  dist = pkgsUnstable.cargo-dist;

  # profiler.firefox.org but local
  firefox-profiler = callPackage ./firefox-profiler.nix {};

  # restore fs mtimes from git
  git-restore-mtime = callPackage ./git-restore-mtime.nix {};

  # block/goose - AI developer agent cli
  goose-cli = callPackage ./goose-cli.nix {};

  # ctz/graviola - devshell for graviola development
  graviola-tools = callPackage ./graviola-tools.nix {};

  # phlip9/imgen - OpenAI API image generator cli
  imgen = callPackage ./imgen.nix {};

  # Claude modelcontextprotocol server for filesystem access
  mcp-server-filesystem = callPackage ./mcp-server-filesystem/default.nix {};

  # MOMW Tools Pack pre-built unstable
  momw-tools-pack = callPackage ./momw-tools-pack.nix {};

  # OpenMW pre-built unstable
  openmw = callPackage ./openmw.nix {};

  # sampling profiler written in Rust, with native firefox-profiler integration
  samply = callPackage ./samply.nix {};
}
