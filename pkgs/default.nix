# phlip9's packages for nixpkgs latest stable release / home-manager
#
# A package belongs here if:
# - it's added to a home-manager config
# - it targets macOS
#
# For NixOS packages, see: <../nixos/pkgs/default.nix>

{ pkgs, sources }:
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

  # cargo-release - release a Rust package
  cargo-release = pkgs.cargo-release;

  # claude-code - Anthropic claude code CLI
  claude-code = callPackage ./claude-code { };

  # codex - OpenAI codex CLI
  codex = callPackage ./codex { };

  # cataclysm-dda - Cataclysm: Dark Days Ahead (game)
  cataclysm-dda = callPackage ./cataclysm-dda.nix { };

  # cataclysm-tlg - Catacylsm: The Last Generation (game)
  cataclysm-tlg = callPackage ./cataclysm-tlg.nix { };

  # dist - build and distribute binary releases
  dist = pkgs.cargo-dist;

  # # profiler.firefox.org but local
  # firefox-profiler = callPackage ./firefox-profiler.nix { };

  # restore fs mtimes from git
  git-restore-mtime = callPackage ./git-restore-mtime.nix { };

  # GitHub App installation-token broker for agent VMs
  github-agent-authd = callPackage ./github-agent-authd { };

  # gh wrapper that injects GitHub App installation tokens per invocation
  github-agent-gh = callPackage ./github-agent-gh {
    inherit (phlipPkgs) github-agent-token;
  };

  # Git credential helper for GitHub App installation tokens
  github-agent-git-credential-helper =
    callPackage ./github-agent-git-credential-helper
      {
        inherit (phlipPkgs) github-agent-token;
      };

  # GitHub App installation-token client for local authd socket API
  github-agent-token = callPackage ./github-agent-token { };

  # github webhook listener for multi-repo command execution
  github-webhook = callPackage ./github-webhook { };

  # # ctz/graviola - devshell for graviola development
  # graviola-tools = callPackage ./graviola-tools.nix { };

  # go-acme/lego - patched Let's Encrypt ACME client
  lego = callPackage ./lego.nix { };

  # MOMW Tools Pack pre-built unstable
  # TODO(phlip9): GitLab CI artifacts expired, need to update URL
  # momw-tools-pack = callPackage ./momw-tools-pack.nix { };

  # mpv with patched umpv
  mpv = callPackage ./mpv { };

  # matugen - material you color generation tool
  matugen = callPackage ./matugen.nix {
    inherit (phlipPkgs) matugen-themes noctalia-shell;
  };

  # matugen-themes - config templates for matugen-generated color schemes
  matugen-themes = callPackage ./matugen-themes.nix { };

  # Marinara Engine lite wrapped in a bubblewrap sandbox
  marinara-engine = callPackage ./marinara-engine/sandbox.nix {
    inherit (phlipPkgs) marinara-engine-unwrapped;
  };
  marinara-engine-unwrapped = callPackage ./marinara-engine { };

  # niks3 - S3-backed Nix binary cache with garbage collection
  niks3 = callPackage (sources.niks3 + "/nix/packages/niks3.nix") { };

  # neovim - wrapped neovim with plugins and tools
  nvim = callPackage ./nvim { };

  # omnara - Omnara CLI
  omnara = callPackage ./omnara { };

  # OpenMW pre-built unstable
  openmw = callPackage ./openmw.nix { };

  # rage-age-compat - provide an age shim to the rage binary
  rage-age-compat = callPackage ./rage-age-compat.nix { };

  # sampling profiler written in Rust, with native firefox-profiler integration
  samply = callPackage ./samply.nix { };

  # sops wrapped with clean nvim (no plugins) for secret editing
  sops = callPackage ./sops.nix { };

  # timep - bash profiler
  timep = callPackage ./timep { };

  # unified launcher for Windows games on Linux
  umu-launcher =
    callPackage (sources.umu-launcher + "/packaging/nix/package.nix")
      {
        inherit (phlipPkgs) umu-launcher-unwrapped;
      };
  umu-launcher-unwrapped =
    callPackage (sources.umu-launcher + "/packaging/nix/unwrapped.nix")
      {
        lastModifiedDate = "20260311";
      };

  # vintagestory (game)
  vintagestory = callPackage ./vintagestory.nix { };

  # my wallpapers
  wallpapers = callPackage ./wallpapers.nix { inherit (phlipPkgs) matugen; };
})
