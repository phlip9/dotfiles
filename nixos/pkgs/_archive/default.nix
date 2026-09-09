# archived nixos pkgs
{
  # `pkgsUnstable` in ../default.nix
  pkgs,
  sources,
}:
let
  callPackage = pkgs.callPackage;

  # TODO(phlip9): remove. figure out how to get buzz-desktop working across
  # stable non-NixOS / unstable NixOS
  phlipPkgs = import ../../../pkgs { inherit pkgs sources; };

  fix =
    f:
    let
      x = f x;
    in
    x;
in

fix (phlipPkgsNixos: {
  _type = "pkgs";

  # buzz - workspace where humans and agents build together
  buzz = callPackage ./buzz {
    inherit (phlipPkgs) claude-agent-acp codex-acp;
  };
})
