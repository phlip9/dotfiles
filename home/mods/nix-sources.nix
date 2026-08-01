# Pin Nix source lookups to the sources used by Home Manager.
{ sources, ... }:
{
  nix = {
    # Reuse Home Manager's nixpkgs for ephemeral flake commands instead of
    # downloading another revision.
    registry = {
      nixpkgs.flake = sources.nixpkgs;
      home-manager.flake = sources.home-manager;
    };

    # Provide legacy angle-bracket lookups without imperative Nix channels.
    channels = {
      inherit (sources) nixpkgs home-manager;
    };
  };
}
