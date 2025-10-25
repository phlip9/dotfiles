# Non-flakes compatibility layer - allows using this repo with nix-build and nix-shell
{...}: import ./lib/flake-outputs.nix
