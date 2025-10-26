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
        lib = import (sources.nixpkgs + "/lib");
        system = null;
        modules = args.modules;
      }
      // (builtins.removeAttrs args [
        "modules"
        "system"
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

          # system.nixos.versionSuffix = ".${inputs.nixpkgs.shortRev}";
          # system.nixos.revision = inputs.nixpkgs.rev;

          nixpkgs.pkgs = pkgs;
          nixpkgs.overlays = lib.mkForce [ ];

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
          # nixpkgs.flake.source = sources.nixpkgs.outPath;
        }
      )
    ];
  };
}

# nixosSystem =
#   args:
#   import ./nixos/lib/eval-config.nix (
#     {
#       lib = final;
#       # Allow system to be set modularly in nixpkgs.system.
#       # We set it to null, to remove the "legacy" entrypoint's
#       # non-hermetic default.
#       system = null;
#
#       modules = args.modules ++ [
#         # This module is injected here since it exposes the nixpkgs self-path in as
#         # constrained of contexts as possible to avoid more things depending on it and
#         # introducing unnecessary potential fragility to changes in flakes itself.
#         #
#         # See: failed attempt to make pkgs.path not copy when using flakes:
#         # https://github.com/NixOS/nixpkgs/pull/153594#issuecomment-1023287913
#         (
#           {
#             config,
#             pkgs,
#             lib,
#             ...
#           }:
#           {
#             config.nixpkgs.flake.source = self.outPath;
#           }
#         )
#       ];
#     }
#     // builtins.removeAttrs args [ "modules" ]
#   );
