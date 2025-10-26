{
  phlipPkgs,
  pkgs,
  sources,
}:
let
  nixosSystem =
    args:
    import (sources.nixpkgs + "/nixos/lib/eval-config.nix") (
      {
        lib = pkgs.lib;
        system = null;
        modules = args.modules;
      }
      // (builtins.removeAttrs args [
        "modules"
      ])
    );
in
{
  # NixOS graphical installer ISO configuration
  nixos-iso = nixosSystem {
    modules = [
      (
        {
          lib,
          config,
          modulesPath,
          ...
        }:
        {
          imports = [
            (modulesPath + "/misc/nixpkgs/read-only.nix")
            (modulesPath + "/installer/cd-dvd/installation-cd-graphical-combined.nix")
          ];

          # force external, read-only pkgs
          nixpkgs = {
            pkgs = pkgs;
            overlays = lib.mkForce pkgs.overlays;
            flake.source = sources.nixpkgs.outPath;
          };

          # enable `nix` command and flakes support
          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
        }
      )
    ];
  };
}
