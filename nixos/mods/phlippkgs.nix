{
  lib,
  pkgs,
  sources,
  ...
}:

{
  options.phlipPkgs = lib.mkOption {
    type = lib.types.pkgs;
  };

  config._module.args.phlipPkgs = import ../../pkgs { inherit pkgs sources; };
}
