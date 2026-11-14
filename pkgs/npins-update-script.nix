# Update named pins in the caller's npins/ directory. Return an updateScript
# command list like nix-update-script, with npins from our pinned nixpkgs.
{ lib, npins }:
{ names }:

assert lib.assertMsg (
  names != [ ]
) "npins-update-script requires at least one pin name";

[
  (lib.getExe npins)
  "--directory"
  "npins"
  "update"
  "--"
]
++ names
