{
  lib,
  pkgs,
  ...
}:

{
  options.phlipPkgs = lib.mkOption {
    type = lib.types.pkgs;
  };

  config.phlipPkgs = import ../../pkgs { inherit pkgs; };
}
