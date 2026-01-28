{ pkgs, sources }:
let
  callPackage = pkgs.callPackage;
in
{
  _type = "pkgs";

  # aider - AI developer agent cli
  aider-chat = pkgs.aider-chat;

  # cargo-release - release a Rust package
  cargo-release = pkgs.cargo-release;

  # claude-code - Anthropic claude code CLI
  claude-code = callPackage ./claude-code { };

  # codex - OpenAI codex CLI
  codex = callPackage ./codex { };

  # cataclysm-dda - Cataclysm: Dark Days Ahead
  cataclysm-dda = callPackage ./cataclysm-dda.nix { };

  # cataclysm-tlg - Catacylsm: The Last Generation
  cataclysm-tlg = callPackage ./cataclysm-tlg.nix { };

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

  # mpv with patched umpv
  mpv = callPackage ./mpv { };

  # niri - scrolling tiling wayland compositor
  niri = callPackage ./niri.nix { };

  # neovim - wrapped neovim with plugins and tools
  nvim = callPackage ./nvim { };

  # nixfmt - standard nix formatter
  # TODO(phlip9): change to `pkgs.nixfmt` after release-25.11
  nixfmt = pkgs.nixfmt-rfc-style;

  # noctalia-shell - sleek & minimal wayland desktop shell using quickshell
  noctalia-shell = callPackage (sources.noctalia-shell + "/nix/package.nix") {
    version = builtins.substring 1 100 sources.noctalia-shell.version;
  };

  # omnara - Omnara CLI
  omnara = callPackage ./omnara { };

  # OpenMW pre-built unstable
  openmw = callPackage ./openmw.nix { };

  # rage-age-compat - provide an age shim to the rage binary
  rage-age-compat = callPackage ./rage-age-compat.nix { };

  # sampling profiler written in Rust, with native firefox-profiler integration
  samply = callPackage ./samply.nix { };

  # xremap - dynamic key remap for X11 and Wayland
  xremap = callPackage ./xremap.nix { };

  # github webhook listener for multi-repo command execution
  github-webhook = callPackage ./github-webhook { };
}
