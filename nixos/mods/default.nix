{ sources }:

[
  (sources.disko + "/module.nix")
  (
    { lib, ... }:
    {
      disko.enableConfig = lib.mkDefault false;
    }
  )

  (sources.noctalia-shell + "/nix/nixos-module.nix")
  ./phlippkgs.nix
  ./xremap.nix
]
