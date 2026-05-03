{
  lib,
  pkgs,
  sources,
  ...
}:

let
  phlipPkgs = import ../../pkgs { inherit pkgs sources; };
  phlipPkgsNixos = import ../pkgs { inherit pkgs sources; };
in
{
  options = {
    phlipPkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = phlipPkgs;
    };
    phlipPkgsNixos = lib.mkOption {
      type = lib.types.pkgs;
      default = phlipPkgsNixos;
    };
  };

  config._module.args = {
    inherit phlipPkgs phlipPkgsNixos;
  };
}
