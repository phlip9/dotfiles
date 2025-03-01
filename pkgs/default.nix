{pkgs}: let
  callPackage = pkgs.callPackage;
in {
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

  # OpenMW pre-built
  openmw = callPackage ./openmw.nix {};

  # sampling profiler written in Rust, with native firefox-profiler integration
  samply = callPackage ./samply.nix {};
}
