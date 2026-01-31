# Release Entrypoints

This document covers the main release.nix files that serve as entrypoints for
Hydra jobsets.

## pkgs/top-level/release.nix - Main Nixpkgs Jobset

**File:** `pkgs/top-level/release.nix` (402 lines)

This is the primary entrypoint for building Nixpkgs packages.

### Function Signature

```nix
{
  nixpkgs ? {
    outPath = (import ../../lib).cleanSource ../..;
    revCount = 1234;
    shortRev = "abcdef";
    revision = "0000000000000000000000000000000000000000";
  },
  system ? builtins.currentSystem,
  officialRelease ? false,
  supportedSystems ? builtins.fromJSON (builtins.readFile ../../ci/supportedSystems.json),
  bootstrapConfigs ? [ ... ],  # Platform triples for bootstrap tools
  scrubJobs ? true,
  nixpkgsArgs ? {
    config = {
      allowAliases = false;
      allowUnfree = false;
      inHydra = true;
      permittedInsecurePackages = [ ... ];
    };
    __allowFileset = false;
  },
  attrNamesOnly ? false,  # For CI eval optimization
}:
```

### Job Structure

The output is composed of two parts joined with `unionOfDisjoint`:

```nix
jobs = unionOfDisjoint nonPackageJobs mapTestOn-packages;
```

#### Non-Package Jobs

Special release-critical jobs that aren't simple package builds:

```nix
nonPackageJobs = {
  # Source tarball with version info and packages.json index
  tarball = import ./make-tarball.nix { ... };

  # Validation: no <nixpkgs> references, case sensitivity, warnings
  release-checks = import ./nixpkgs-basic-release-checks.nix { ... };

  # Documentation
  manual = pkgs.nixpkgs-manual.override { inherit nixpkgs; };

  # Performance metrics tracking
  metrics = import ./metrics.nix { inherit pkgs nixpkgs; };

  # Darwin aggregate gate
  darwin-tested = pkgs.releaseTools.aggregate { ... };

  # Unstable channel aggregate gate
  unstable = pkgs.releaseTools.aggregate { ... };

  # Bootstrap toolchains for all platforms
  stdenvBootstrapTools = genAttrs bootstrapConfigs ( ... );
};
```

#### Package Jobs

All packages mapped to their supported platforms:

```nix
packageJobs = packagePlatforms pkgs // {
  # Multi-GHC Haskell Language Server builds
  haskell = packagePlatforms pkgs.haskell // {
    packages = genAttrs [ "ghc96" "ghc98" "ghc910" "ghc912" ] ( ... );
  };

  # Alternative toolchain stdenvs
  pkgsLLVM.stdenv = [ "x86_64-linux" "aarch64-linux" ];
  pkgsArocc.stdenv = [ "x86_64-linux" "aarch64-linux" ];
  pkgsZig.stdenv = [ "x86_64-linux" "aarch64-linux" ];
  pkgsMusl.stdenv = [ "x86_64-linux" "aarch64-linux" ];
  pkgsStatic.stdenv = [ "x86_64-linux" "aarch64-linux" ];

  # ROCm packages use their own release mechanism
  pkgsRocm = pkgs.rocmPackages.meta.release-packagePlatforms;
};
```

### Aggregate Jobs Example

The `unstable` aggregate defines what must pass for channel updates:

```nix
unstable = pkgs.releaseTools.aggregate {
  name = "nixpkgs-${jobs.tarball.version}";
  meta.description = "Release-critical builds for the Nixpkgs unstable channel";
  constituents = [
    jobs.tarball
    jobs.release-checks
    jobs.metrics
    jobs.manual
    jobs.tests.lib-tests.x86_64-linux
    jobs.stdenv.x86_64-linux
    jobs.cargo.x86_64-linux
    jobs.go.x86_64-linux
    jobs.linux.x86_64-linux
    jobs.nix.x86_64-linux
    jobs.python3.x86_64-linux
    jobs.firefox-unwrapped.x86_64-linux
    # ... more critical packages
  ]
  ++ collect isDerivation jobs.stdenvBootstrapTools
  ++ optionals supportDarwin.x86_64 [ ... ]
  ++ optionals supportDarwin.aarch64 [ ... ];
};
```

## nixos/release.nix - NixOS Artifacts

**File:** `nixos/release.nix` (566 lines)

Builds NixOS-specific artifacts: ISOs, VM images, tests.

### Key Structure

```nix
{
  nixpkgs ? { ... },
  stableBranch ? false,
  supportedSystems ? [ "x86_64-linux" "aarch64-linux" ],
  configuration ? { },
  attrNamesOnly ? false,
}:
```

### Test Discovery

Tests are discovered from `nixos/tests/all-tests.nix`:

```nix
allTestsForSystem = system:
  import ./tests/all-tests.nix {
    inherit system;
    pkgs = import ./.. { inherit system; };
    callTest = config:
      if attrNamesOnly then hydraJob config.test
      else { ${system} = hydraJob config.test; };
  };

allTests = foldAttrs recursiveUpdate { }
  (map allTestsForSystem
    (if attrNamesOnly then [ (head supportedSystems) ] else supportedSystems));
```

### Build Outputs

```nix
{
  channel = import lib/make-channel.nix { ... };

  # Documentation
  manualHTML = buildFromConfig ({ ... }: { }) (config: config.system.build.manual.manualHTML);
  manualEpub = ...;
  options = ...;

  # Installation media
  iso_minimal = forAllSystems (system: makeIso { ... });
  iso_graphical = forAllSystems (system: makeIso { ... });

  # SD card images (ARM)
  sd_image = forMatchingSystems [ "armv6l-linux" "armv7l-linux" "aarch64-linux" ] ...;

  # Cloud images
  amazonImage = forMatchingSystems [ "x86_64-linux" "aarch64-linux" ] ...;
  proxmoxImage = forMatchingSystems [ "x86_64-linux" ] ...;
  incusContainerImage = forMatchingSystems [ "x86_64-linux" "aarch64-linux" ] ...;

  # Network boot
  netboot = forMatchingSystems supportedSystems ...;
  kexec = forMatchingSystems supportedSystems ...;

  # All tests
  tests = allTests;

  # Closure size tracking
  closures = {
    smallContainer = makeClosure ( ... );
    tinyContainer = makeClosure ( ... );
    kde = makeClosure ( ... );
    gnome = makeClosure ( ... );
    # ...
  };
}
```

## nixos/release-combined.nix - Channel Gating

**File:** `nixos/release-combined.nix` (199 lines)

Combines NixOS and Nixpkgs into a single jobset for channel updates.

```nix
{
  nixos = removeMaintainers (import ./release.nix { ... });
  nixpkgs = removeAttrs (removeMaintainers (import ../pkgs/top-level/release.nix { ... }))
    [ "unstable" ];

  tested = pkgs.releaseTools.aggregate {
    name = "nixos-${nixos.channel.version}";
    constituents = [
      "nixos.channel"
      (onFullSupported "nixos.iso_minimal")
      (onFullSupported "nixos.tests.login")
      (onFullSupported "nixos.tests.openssh")
      # ... comprehensive test list
      [ "nixpkgs.tarball" "nixpkgs.release-checks" ]
    ];
  };
}
```

## Specialized Release Files

### release-small.nix

Minimal jobset for `stdenv-updates` branch testing:

```nix
# ~50 essential packages only
{
  tarball = import ./make-tarball.nix { ... };
}
// (mapTestOn {
  aspell = all;
  bash = all;
  gcc = all;
  glibc = linux;
  nix = all;
  python3 = unix;
  stdenv = all;
  # ...
})
```

### release-staging.nix

Even more minimal - just stdenv on all platforms for staging merges.

### release-cross.nix

Cross-compilation smoke tests for ~30 target platforms:

```nix
{
  crossMingw32 = mapTestOnCross systems.examples.mingw-msvcrt-i686 windowsCommon;
  aarch64 = mapTestOnCross systems.examples.aarch64-multiplatform linuxCommon;
  riscv64 = mapTestOnCross systems.examples.riscv64 linuxCommon;
  wasi32 = mapTestOnCross systems.examples.wasi32 wasiCommon;
  arm-embedded = mapTestOnCross systems.examples.arm-embedded embedded;
  # ... many more
  bootstrapTools = { ... };  # Cross-built bootstrap tools
}
```

### release-haskell.nix

Multi-compiler Haskell package testing:

```nix
released = [ "ghc948" "ghc967" "ghc984" "ghc9102" "ghc9103" "ghc9122" "ghc9123" ];

jobs = recursiveUpdateMany [
  (mapTestOn {
    haskellPackages = packagePlatforms pkgs.haskellPackages;
    haskell.compiler = packagePlatforms pkgs.haskell.compiler;
    # top-level Haskell-dependent packages
    inherit (pkgsPlatforms) pandoc stack shellcheck ...;
  })
  (versionedCompilerJobs {
    haskell-language-server = released;
    cabal-install = lib.subtractLists [ ... ] released;
    # ...
  })
  {
    mergeable = pkgs.releaseTools.aggregate { ... };
    maintained = pkgs.releaseTools.aggregate { ... };
  }
];
```

### release-python.nix

Python package testing with recursive discovery:

```nix
packagePython = mapAttrs (name: value:
  let res = builtins.tryEval (
    if isDerivation value then
      value.meta.isBuildPythonPackage or [ ]
    else if value.recurseForDerivations or false || value.recurseForRelease or false then
      packagePython value
    else [ ]
  );
  in optionals res.success res.value
);

jobs = {
  tested = pkgs.releaseTools.aggregate {
    constituents = [
      jobs.python313Packages.sphinx.x86_64-linux
      jobs.python313Packages.requests.x86_64-linux
      # ...
    ];
  };
} // (mapTestOn (packagePython pkgs));
```
