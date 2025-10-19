# Non-flakes compatibility layer - allows using this repo with nix-build and nix-shell
{...}: let
  inherit (builtins) fetchTarball fromJSON mapAttrs readFile removeAttrs;

  # Read ./flake.lock
  lockFile = fromJSON (readFile ./flake.lock);

  lockedInputs = removeAttrs lockFile.nodes ["root"];

  fetchLockedFlake = locked:
    if locked.type != "github"
    then throw "error: unsupported flake input type: ${locked.type}"
    else
      fetchTarball {
        url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
        sha256 = locked.narHash;
      };

  getLockedFlake = name: input: let
    locked = input.locked;
    rev = locked.rev or "dirty";
    src = fetchLockedFlake locked;
    flake = import (src + "/flake.nix");
    flakeExt = {
      lastModified = locked.lastModified;
      narHash = locked.narHash;
      outPath = src;
      owner = locked.owner;
      repo = locked.repo;
      rev = rev;
      shortRev = builtins.substring 0 7 rev;
    };
    outputs = flake.outputs ({
        self = outputs // flakeExt;
      }
      # TODO(phlip9): actually pass correct inputs
      // (
        if name == "home-manager"
        then {nixpkgs = input.nixpkgs;}
        else {}
      ));
  in
    outputs // flakeExt;

  # Fetch all inputs
  inputs = mapAttrs getLockedFlake lockedInputs;

  # Build the flake outputs with fetched inputs
  outputs = (import ./flake.nix).outputs (inputs // {self = outputs;});

  # Add convenience currentSystem attribute to each output
  outputsWithCurrentSystem =
    builtins.mapAttrs (
      _name: value:
        if value ? ${builtins.currentSystem}
        then (value // {currentSystem = value.${builtins.currentSystem};})
        else value
    )
    outputs;
in
  outputsWithCurrentSystem
