# Pin Nix source lookups to the sources used by installed NixOS systems.
{ sources, ... }:
let
  nixpkgsSource = sources.nixos-unstable.outPath;
  homeManagerSource = sources.home-manager.outPath;
in
{
  nix = {
    # The source pins replace mutable, per-user Nix channels.
    channel.enable = false;

    # Configure legacy angle-bracket lookups directly, independent of the
    # flake registry.
    nixPath = [
      "nixpkgs=${nixpkgsSource}"
      "home-manager=${homeManagerSource}"
    ];

    # Reuse the same pins for unqualified flake references.
    registry = {
      nixpkgs.to = {
        type = "path";
        path = nixpkgsSource;
      };
      home-manager.to = {
        type = "path";
        path = homeManagerSource;
      };
    };
  };
}
