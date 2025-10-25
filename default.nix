# Non-flakes compatibility layer - allows using this repo with nix-build
let
  outputs = import ./lib/flake-outputs.nix;
in
  outputs
  // (
    if outputs ? packages.${builtins.currentSystem}
    then outputs.packages.${builtins.currentSystem}
    else {}
  )
