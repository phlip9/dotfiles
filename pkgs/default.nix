{
  pkgs,
  pkgsUnstable,
}: let
  callPackage = pkgs.callPackage;
in {
  # aider - AI developer agent cli
  aider-chat = pkgsUnstable.aider-chat;

  # cli to load .env
  dotenvy = callPackage ./dotenvy.nix {};

  # profiler.firefox.org but local
  firefox-profiler = callPackage ./firefox-profiler.nix {};

  # restore fs mtimes from git
  git-restore-mtime = callPackage ./git-restore-mtime.nix {};

  # block/goose - AI developer agent cli
  goose-cli = callPackage ./goose-cli.nix {};

  # Claude modelcontextprotocol server for filesystem access
  mcp-server-filesystem = callPackage ./mcp-server-filesystem/default.nix {};

  # MOMW Tools Pack pre-built unstable
  momw-tools-pack = callPackage ./momw-tools-pack.nix {};

  # OpenMW pre-built unstable
  openmw = callPackage ./openmw.nix {};

  # sampling profiler written in Rust, with native firefox-profiler integration
  samply = callPackage ./samply.nix {};
}
