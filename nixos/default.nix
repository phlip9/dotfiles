{
  # be careful not to pass `pkgs` eval to normal NixOS system evals
  pkgs,
  nixpkgs,
}:
let
  # be careful not to pass `pkgs` eval to normal NixOS system evals. they should
  # control their own package set.
  nixosSystem =
    args:
    import (nixpkgs + "/nixos/lib/eval-config.nix") (
      {
        lib = import (nixpkgs + "/lib");
        system = null;
        modules = args.modules;
        extraModules = import ./mods;
      }
      // (builtins.removeAttrs args [ "modules" ])
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

          # force external, read-only pkgs for iso
          nixpkgs = {
            pkgs = pkgs;
            overlays = lib.mkForce pkgs.overlays;
            flake.source = nixpkgs.outPath;
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

  # phlipdesk experimental NixOS install
  phlipnixos = nixosSystem {
    modules = [ ./phlipnixos/default.nix ];
  };
}
