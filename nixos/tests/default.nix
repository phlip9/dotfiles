# NixOS VM tests
{
  pkgs,
  sources,
}:

let
  nixpkgs = sources.nixos-unstable;
  lib = pkgs.lib;

  # Replicate nixosSystem setup but for tests
  mkNixosTest =
    testModuleFile:
    let
      # Import extraModules just like nixosSystem does
      extraModules = import ../mods { inherit sources; };

      testModule = import testModuleFile { inherit lib sources; };
    in
    import (nixpkgs + "/nixos/tests/make-test-python.nix") (
      testModule
      // {
        nodes = lib.mapAttrs (
          _name: nodeConfig:
          { config, ... }:
          {
            imports = [ nodeConfig ] ++ extraModules;
            _module.args.sources = sources;
          }
        ) testModule.nodes;
      }
    );
in

{
  github-webhook = mkNixosTest ./github-webhook.nix;
}
