# Release Library (release-lib.nix)

**File:** `pkgs/top-level/release-lib.nix` (263 lines)

This module provides the core abstractions for mapping packages to their
supported platforms and constructing the Hydra job tree.

## Module Interface

```nix
{
  supportedSystems,
  system ? builtins.currentSystem,
  packageSet ? (import ../..),
  scrubJobs ? true,
  nixpkgsArgs ? { ... },
}:
```

## Package Set Memoization

The key optimization is memoizing package set instantiation per system. Without
this, Nixpkgs would be re-evaluated for every package/platform combination.

```nix
mkPkgsFor = crossSystem:
  let
    packageSet' = args: packageSet (args // { inherit crossSystem; } // nixpkgsArgs);

    # Pre-instantiate all supported systems
    pkgs_x86_64_linux = packageSet' { system = "x86_64-linux"; };
    pkgs_i686_linux = packageSet' { system = "i686-linux"; };
    pkgs_aarch64_linux = packageSet' { system = "aarch64-linux"; };
    pkgs_riscv64_linux = packageSet' { system = "riscv64-linux"; };
    pkgs_aarch64_darwin = packageSet' { system = "aarch64-darwin"; };
    pkgs_armv6l_linux = packageSet' { system = "armv6l-linux"; };
    pkgs_armv7l_linux = packageSet' { system = "armv7l-linux"; };
    pkgs_x86_64_darwin = packageSet' { system = "x86_64-darwin"; };
    pkgs_x86_64_freebsd = packageSet' { system = "x86_64-freebsd"; };
    pkgs_i686_freebsd = packageSet' { system = "i686-freebsd"; };
    pkgs_i686_cygwin = packageSet' { system = "i686-cygwin"; };
    pkgs_x86_64_cygwin = packageSet' { system = "x86_64-cygwin"; };
  in
  system:
    if system == "x86_64-linux" then pkgs_x86_64_linux
    else if system == "i686-linux" then pkgs_i686_linux
    else if system == "aarch64-linux" then pkgs_aarch64_linux
    else if system == "riscv64-linux" then pkgs_riscv64_linux
    else if system == "aarch64-darwin" then pkgs_aarch64_darwin
    else if system == "armv6l-linux" then pkgs_armv6l_linux
    else if system == "armv7l-linux" then pkgs_armv7l_linux
    else if system == "x86_64-darwin" then pkgs_x86_64_darwin
    else if system == "x86_64-freebsd" then pkgs_x86_64_freebsd
    else if system == "i686-freebsd" then pkgs_i686_freebsd
    else if system == "i686-cygwin" then pkgs_i686_cygwin
    else if system == "x86_64-cygwin" then pkgs_x86_64_cygwin
    else abort "unsupported system type: ${system}";

# Native compilation
pkgsFor = pkgsForCross null;

# Cross compilation with additional memoization
pkgsForCross =
  let
    examplesByConfig = flip mapAttrs' systems.examples (
      _: crossSystem: nameValuePair crossSystem.config {
        inherit crossSystem;
        pkgsFor = mkPkgsFor crossSystem;
      }
    );
    native = mkPkgsFor null;
  in
  crossSystem:
    let candidate = examplesByConfig.${crossSystem.config} or null;
    in
    if crossSystem == null then native
    else if candidate != null && matchAttrs crossSystem candidate.crossSystem then
      candidate.pkgsFor
    else mkPkgsFor crossSystem;  # uncached fallback
```

## Platform Matching

### supportedMatches

Filters `supportedSystems` to those matching platform patterns:

```nix
supportedMatches =
  let
    supportedPlatforms = map (system: systems.elaborate { inherit system; }) supportedSystems;
  in
  metaPatterns:
    let
      anyMatch = platform: any (meta.platformMatch platform) metaPatterns;
      matchingPlatforms = filter anyMatch supportedPlatforms;
    in
    map ({ system, ... }: system) matchingPlatforms;
```

### forMatchingSystems

Generate attributes for systems matching patterns:

```nix
forMatchingSystems = metaPatterns: genAttrs (supportedMatches metaPatterns);
```

## Core Mapping Functions

### testOn / testOnCross

Build a package on matching platforms:

```nix
# Native builds
testOn = testOnCross null;

# Cross builds
testOnCross = crossSystem: metaPatterns: f:
  forMatchingSystems metaPatterns (system:
    hydraJob' (f (pkgsForCross crossSystem system))
  );
```

Usage example:
```nix
# Build hello on all Linux systems
helloJobs = testOn linux (pkgs: pkgs.hello);
# Result: { x86_64-linux = <drv>; aarch64-linux = <drv>; ... }
```

### mapTestOn

The key function that transforms a nested attrset of platform lists into
actual derivations:

```nix
mapTestOn = _mapTestOnHelper id null;

_mapTestOnHelper = f: crossSystem:
  mapAttrsRecursive (path: metaPatterns:
    testOnCross crossSystem metaPatterns (pkgs:
      f (getAttrFromPath path pkgs)
    )
  );
```

Usage:
```nix
mapTestOn {
  hello = [ "x86_64-linux" "aarch64-linux" ];
  nested.package = [ "x86_64-darwin" ];
}
# Result:
# {
#   hello.x86_64-linux = <drv>;
#   hello.aarch64-linux = <drv>;
#   nested.package.x86_64-darwin = <drv>;
# }
```

### mapTestOnCross

For cross-compilation with maintainer metadata:

```nix
mapTestOnCross = _mapTestOnHelper (addMetaAttrs {
  maintainers = crossMaintainers;
});
```

## Package Platform Extraction

### getPlatforms

Extract the list of platforms a derivation should build on:

```nix
getPlatforms = drv:
  drv.meta.hydraPlatforms
    or (subtractLists (drv.meta.badPlatforms or [ ])
                      (drv.meta.platforms or supportedSystems));
```

Priority order:
1. `meta.hydraPlatforms` - explicit Hydra platform list (if set)
2. `meta.platforms - meta.badPlatforms` - computed from platform metadata
3. `supportedSystems` - fallback to all supported systems

### recursiveMapPackages

Recursively map a function over all derivations in a package set:

```nix
recursiveMapPackages = f:
  mapAttrs (name: value:
    if isDerivation value then
      f value
    else if value.recurseForDerivations or false || value.recurseForRelease or false then
      recursiveMapPackages f value
    else
      [ ]
  );
```

The recursion respects two flags:
- `recurseForDerivations` - standard Nixpkgs recursion marker
- `recurseForRelease` - Hydra-specific recursion marker

### packagePlatforms

Combines the above to extract platforms for all packages:

```nix
packagePlatforms = recursiveMapPackages getPlatforms;
```

Example output:
```nix
{
  hello = [ "aarch64-linux" "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ];
  pythonPackages = {
    requests = [ "aarch64-linux" "x86_64-linux" ];
    # ...
  };
}
```

## The hydraJob Function

When `scrubJobs = true`, derivations are wrapped with `hydraJob`:

```nix
hydraJob' = if scrubJobs then hydraJob else id;
```

The actual `hydraJob` function (from `lib/customisation.nix`):

```nix
hydraJob = drv:
  let
    outputs = drv.outputs or [ "out" ];

    commonAttrs = {
      inherit (drv) name system meta;
      inherit outputs;
    }
    // optionalAttrs (drv._hydraAggregate or false) {
      _hydraAggregate = true;
      constituents = map hydraJob (flatten drv.constituents);
    }
    // (listToAttrs outputsList);

    makeOutput = outputName:
      let output = drv.${outputName};
      in {
        name = outputName;
        value = commonAttrs // {
          outPath = output.outPath;
          drvPath = output.drvPath;
          type = "derivation";
          inherit outputName;
        };
      };

    outputsList = map makeOutput outputs;
    drv' = (head outputsList).value;
  in
  if drv == null then null else deepSeq drv' drv';
```

Key characteristics:
- Preserves only: `name`, `system`, `meta`, `outputs`, output paths
- Strips all build-time attributes (src, buildInputs, etc.)
- Uses `deepSeq` to force evaluation and enable GC of intermediate values
- Handles aggregate jobs via `_hydraAggregate` flag

## Module Exports

```nix
{
  # Platform groups
  inherit (platforms) unix linux darwin cygwin all;

  # Core functions
  inherit
    assertTrue
    forAllSystems
    forMatchingSystems
    hydraJob'
    lib
    mapTestOn
    mapTestOnCross
    recursiveMapPackages
    getPlatforms
    packagePlatforms
    pkgs
    pkgsFor
    pkgsForCross
    supportedMatches
    testOn
    testOnCross
    ;
}
```
