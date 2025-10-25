# Non-flakes compatibility layer - allows using this repo with nix-build and nix-shell
let
  # Read ./flake.lock
  lockFile = builtins.fromJSON (builtins.readFile ../flake.lock);

  lockedInputs = builtins.removeAttrs lockFile.nodes ["root"];

  fetchLockedFlake =
    builtins.fetchTree or (locked:
      if locked.type != "github"
      then throw "error: unsupported flake input type: ${locked.type}"
      else {
        outPath = builtins.fetchTarball {
          url = "https://api.github.com/repos/${locked.owner}/${locked.repo}/tarball/${locked.rev}";
          sha256 = locked.narHash;
        };
        rev = locked.rev;
        shortRev = builtins.substring 0 7 locked.rev;
        lastModified = locked.lastModified;
        lastModifiedDate = "19700101000000";
        narHash = locked.narHash;
      });

  getLockedFlake = name: input: let
    locked = input.locked;
    src = fetchLockedFlake locked;
    flake = import (src + "/flake.nix");
    # TODO(phlip9): actually pass correct inputs
    inputs =
      if name == "home-manager"
      then {nixpkgs = input.nixpkgs;}
      else {};
    outputs = flake.outputs ({self = outputs // src;} // inputs);
  in
    outputs
    // src
    // {
      inherit outputs;
      inherit inputs;
      _type = "flake";
    };

  # Fetch all inputs
  inputs = builtins.mapAttrs getLockedFlake lockedInputs;

  # Build the flake outputs with fetched inputs
  outputs = (import ../flake.nix).outputs ({self = outputs;} // inputs);
in
  outputs
