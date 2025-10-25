# Non-flakes compatibility layer - allows using this repo with nix-shell
let
  outputs = import ./lib/flake-outputs.nix;
in
  outputs
  // (
    if outputs ? devShells.${builtins.currentSystem}
    then outputs.devShells.${builtins.currentSystem}
    else {}
  )
