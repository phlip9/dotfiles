# Pin Nix source lookups to the sources used by installed NixOS systems.
{ lib, sources, ... }:
let
  nixpkgsSource = sources.nixos-unstable.outPath;
  homeManagerSource = sources.home-manager.outPath;
in
{
  # Include all npins sources in the system closure to speed up eval on CppNix.
  #
  # Why: CppNix 2.35 lazy trees only mount `fetchTarball` results from the git
  # tarball cache. Pins that are only `import`ed (ex: disko, sops-nix modules)
  # never get copied into the store, or get GC'd when unrooted. Every eval then
  # misses the store fast path and, once `tarball-ttl` expires (~ every hour),
  # re-checks each pin over the network ("unpacking '...' into the Git cache").
  #
  # Keeping them in the closure lets evals on this machine (incl. nixbot CI)
  # stay local.
  #
  # Not affected: Lix
  system.extraDependencies = lib.filter lib.isStorePath (
    map (source: source.outPath) (
      # Drop npins' top-level `__functor`
      lib.attrValues (removeAttrs sources [ "__functor" ])
    )
  );

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
