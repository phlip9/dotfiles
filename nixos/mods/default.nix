{ sources }:

[
  (sources.noctalia-shell + "/nix/nixos-module.nix")
  ./phlippkgs.nix
  ./xremap.nix
]
