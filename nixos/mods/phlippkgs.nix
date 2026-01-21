{
  lib,
  pkgs,
  sources,
  ...
}:

let
  phlipPkgs = import ../../pkgs { inherit pkgs sources; };
in
{
  options.phlipPkgs = lib.mkOption {
    type = lib.types.pkgs;
    default = phlipPkgs;
  };

  config._module.args.phlipPkgs = phlipPkgs;
}
