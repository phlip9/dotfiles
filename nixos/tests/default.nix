# NixOS VM tests
{
  pkgs,
  sources,
}:

let
  nixpkgs = sources.nixos-unstable;
  lib = import (nixpkgs + "/lib");

  # Helper to create a NixOS test with proper setup
  mkNixosTest =
    testModule:
    import (nixpkgs + "/nixos/tests/make-test-python.nix") (testModule { inherit lib pkgs sources; });
in

{
  github-webhook = mkNixosTest (import ./github-webhook.nix);
}
