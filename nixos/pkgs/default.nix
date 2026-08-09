# phlip9's packages for nixos-unstable
#
# A package belongs here if:
# - it targets NixOS only
# - it only works on the latest nixos-unstable
#
# For nixpkgs stable and home-manager packages, see: <../pkgs/default.nix>

{
  # `pkgsUnstable` in ../default.nix
  pkgs,
  sources,
}:
let
  callPackage = pkgs.callPackage;

  # TODO(phlip9): remove. figure out how to get buzz-desktop working across
  # stable non-NixOS / unstable NixOS
  phlipPkgs = import ../../pkgs { inherit pkgs sources; };

  fix =
    f:
    let
      x = f x;
    in
    x;
in

fix (phlipPkgsNixos: {
  _type = "pkgs";

  # awakened-poe-trade - Path of Exile trading app for price checking
  awakened-poe-trade = callPackage ./awakened-poe-trade.nix { };

  # buzz - workspace where humans and agents build together
  buzz = callPackage ./buzz {
    inherit (phlipPkgs) claude-agent-acp codex-acp;
  };

  # GitHub App installation-token broker for agent VMs
  github-agent-authd = callPackage ./github-agent-authd { };

  # github webhook listener for multi-repo command execution
  github-webhook = callPackage ./github-webhook { };

  # matugen - material you color generation tool
  matugen = callPackage ./matugen.nix {
    inherit (phlipPkgsNixos) matugen-themes;
  };

  # matugen-themes - config templates for matugen-generated color schemes
  matugen-themes = callPackage ./matugen-themes.nix { };

  # mpv with patched umpv
  mpv = callPackage ./mpv { };

  # niks3 - S3-backed Nix binary cache with garbage collection
  niks3 = callPackage (sources.niks3 + "/nix/packages/niks3.nix") { };

  # nixbot-cli - inspect and control nixbot CI from the `nbo` CLI
  nixbot-cli = pkgs.python3Packages.callPackage (
    sources.nixbot + "/packages/nixbot-cli.nix"
  ) { };

  # paseo-relay - self-hosted relay for Paseo daemon/client traffic
  paseo-relay = callPackage ./paseo-relay.nix { };

  # seahorse-ssh-askpass - tiny package that links to seahorse's ssh-askpass
  seahorse-ssh-askpass = callPackage ./seahorse-ssh-askpass.nix { };

  # my wallpapers
  wallpapers = callPackage ./wallpapers.nix { inherit (phlipPkgsNixos) matugen; };
})
