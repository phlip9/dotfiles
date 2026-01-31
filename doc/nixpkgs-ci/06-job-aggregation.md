# Job Aggregation

This document covers how nixpkgs creates aggregate jobs and channel artifacts
for Hydra.

## pkgs.releaseTools

**File:** `pkgs/build-support/release/default.nix` (211 lines)

This module provides tools for creating release artifacts.

## aggregate Function

Creates a Hydra aggregate job that succeeds only if all constituents succeed:

```nix
aggregate = { name, constituents, meta ? { } }:
  pkgs.runCommand name
    {
      inherit constituents meta;
      preferLocalBuild = true;
      _hydraAggregate = true;
    }
    ''
      mkdir -p $out/nix-support
      touch $out/nix-support/hydra-build-products
      echo $constituents > $out/nix-support/hydra-aggregate-constituents

      # Propagate build failures
      for i in $constituents; do
        if [ -e $i/nix-support/failed ]; then
          touch $out/nix-support/failed
        fi
      done
    '';
```

### Key Attributes

- `_hydraAggregate = true` - Signals to Hydra this is an aggregate job
- `constituents` - List of derivations that must all succeed
- Creates `nix-support/hydra-aggregate-constituents` for Hydra to parse
- Propagates failures via `nix-support/failed` marker

### Usage Example

```nix
# From release.nix
unstable = pkgs.releaseTools.aggregate {
  name = "nixpkgs-${jobs.tarball.version}";
  meta.description = "Release-critical builds for the Nixpkgs unstable channel";
  constituents = [
    jobs.tarball
    jobs.release-checks
    jobs.metrics
    jobs.stdenv.x86_64-linux
    jobs.nix.x86_64-linux
    jobs.python3.x86_64-linux
    # ...
  ];
};
```

## channel Function

Creates a Hydra channel artifact with source tarball:

```nix
channel = { name, src, constituents ? [ ], meta ? { }, isNixOS ? true, ... }@args:
  stdenv.mkDerivation ({
    preferLocalBuild = true;
    _hydraAggregate = true;

    dontConfigure = true;
    dontBuild = true;

    patchPhase = optionalString isNixOS ''
      touch .update-on-nixos-rebuild
    '';

    installPhase = ''
      mkdir -p $out/{tarballs,nix-support}

      tar cJf "$out/tarballs/nixexprs.tar.xz" \
        --owner=0 --group=0 --mtime="1970-01-01 00:00:00 UTC" \
        --transform='s!^\.!${name}!' .

      echo "channel - $out/tarballs/nixexprs.tar.xz" > "$out/nix-support/hydra-build-products"
      echo $constituents > "$out/nix-support/hydra-aggregate-constituents"

      # Propagate build failures
      for i in $constituents; do
        if [ -e "$i/nix-support/failed" ]; then
          touch "$out/nix-support/failed"
        fi
      done
    '';

    meta = meta // {
      isHydraChannel = true;
    };
  } // removeAttrs args [ "meta" ]);
```

### Hydra Build Products

The `nix-support/hydra-build-products` file tells Hydra what artifacts to
expose. Format: `<type> <subtype> <path>`

```
channel - $out/tarballs/nixexprs.tar.xz
file json-br $out/packages.json.br
```

## hydraJob Handling of Aggregates

From `lib/customisation.nix`, aggregates are specially handled:

```nix
hydraJob = drv:
  let
    commonAttrs = {
      inherit (drv) name system meta;
      inherit outputs;
    }
    // optionalAttrs (drv._hydraAggregate or false) {
      _hydraAggregate = true;
      constituents = map hydraJob (flatten drv.constituents);
    }
    // (listToAttrs outputsList);
    # ...
  in
  # ...
```

The `constituents` are recursively wrapped with `hydraJob` to ensure memory
efficiency throughout.

## Aggregate Job Examples

### darwin-tested

Gates Darwin channel updates:

```nix
darwin-tested = pkgs.releaseTools.aggregate {
  name = "nixpkgs-darwin-${jobs.tarball.version}";
  meta.description = "Release-critical builds for the Nixpkgs darwin channel";
  constituents = [
    jobs.tarball
    jobs.release-checks
  ]
  ++ optionals supportDarwin.x86_64 [
    jobs.ghc.x86_64-darwin
    jobs.git.x86_64-darwin
    jobs.nix.x86_64-darwin
    jobs.python3.x86_64-darwin
    jobs.rustc.x86_64-darwin
    # UI apps
    jobs.inkscape.x86_64-darwin
    jobs.emacs.x86_64-darwin
    # ...
  ]
  ++ optionals supportDarwin.aarch64 [
    # Similar list for aarch64-darwin
  ];
};
```

### Haskell mergeable

From `release-haskell.nix`:

```nix
mergeable = pkgs.releaseTools.aggregate {
  name = "haskell-updates-mergeable";
  meta = {
    description = ''
      Critical haskell packages that should work at all times,
      serves as minimum requirement for an update merge
    '';
    teams = [ lib.teams.haskell ];
  };
  constituents = accumulateDerivations [
    jobs.tests.haskell
    jobs.cabal-install
    jobs.pandoc
    jobs.stack
    jobs.haskellPackages.xmonad
    # ...
  ];
};
```

### NixOS tested

From `nixos/release-combined.nix`:

```nix
tested = pkgs.releaseTools.aggregate {
  name = "nixos-${nixos.channel.version}";
  meta = {
    description = "Release-critical builds for the NixOS channel";
  };
  constituents = pkgs.lib.concatLists [
    [ "nixos.channel" ]
    (onFullSupported "nixos.dummy")
    (onAllSupported "nixos.iso_minimal")
    (onFullSupported "nixos.tests.login")
    (onFullSupported "nixos.tests.openssh")
    (onFullSupported "nixos.tests.gnome")
    # ... many more tests
    [ "nixpkgs.tarball" "nixpkgs.release-checks" ]
  ];
};
```

## Helper: accumulateDerivations

From `release-haskell.nix`, flattens nested job structures for aggregate
constituents:

```nix
accumulateDerivations = jobList:
  lib.concatMap (attrs:
    if lib.isDerivation attrs then
      [ attrs ]
    else
      lib.optionals (lib.isAttrs attrs)
        (accumulateDerivations (lib.attrValues attrs))
  ) jobList;
```

This allows:
```nix
constituents = accumulateDerivations [
  jobs.tests.haskell  # Nested attrset of tests
  jobs.pandoc         # Single derivation
  jobs.haskellPackages.lens  # From package set
];
```

## Other Release Tools

### sourceTarball

Creates reproducible source tarballs:

```nix
sourceTarball = args:
  import ./source-tarball.nix ({
    inherit lib stdenv autoconf automake libtool;
  } // args);
```

### binaryTarball

Creates binary distribution tarballs:

```nix
binaryTarball = args:
  import ./binary-tarball.nix ({
    inherit lib stdenv;
  } // args);
```

### nixBuild

Wrapper for standard nix builds with release metadata:

```nix
nixBuild = args:
  import ./nix-build.nix ({
    inherit lib stdenv;
  } // args);
```

### Coverage and Analysis

```nix
coverageAnalysis = args:
  nixBuild ({
    inherit lcov enableGCOVInstrumentation makeGCOVReport;
    doCoverageAnalysis = true;
  } // args);

clangAnalysis = args:
  nixBuild ({
    inherit clang-analyzer;
    doClangAnalysis = true;
  } // args);
```
