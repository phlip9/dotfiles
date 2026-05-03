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
})
