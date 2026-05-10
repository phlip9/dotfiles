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

  fix =
    f:
    let
      x = f x;
    in
    x;
in

fix (phlipPkgsNixos: {
  _type = "pkgs";

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

  # unified launcher for Windows games on Linux
  umu-launcher =
    callPackage (sources.umu-launcher + "/packaging/nix/package.nix")
      {
        inherit (phlipPkgsNixos) umu-launcher-unwrapped;
      };
  umu-launcher-unwrapped =
    callPackage (sources.umu-launcher + "/packaging/nix/unwrapped.nix")
      {
        lastModifiedDate = "20260311";
      };

  # vintagestory (game)
  vintagestory = callPackage ./vintagestory.nix { };

  # my wallpapers
  wallpapers = callPackage ./wallpapers.nix { inherit (phlipPkgsNixos) matugen; };
})
