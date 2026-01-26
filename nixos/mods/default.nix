{ sources }:

[
  (sources.disko + "/module.nix")
  (
    { lib, ... }:
    {
      disko.enableConfig = lib.mkDefault false;
    }
  )

  (sources.sops-nix + "/modules/sops/default.nix")
  (sources.noctalia-shell + "/nix/nixos-module.nix")
  ./phlippkgs.nix
  ./xremap.nix
]
