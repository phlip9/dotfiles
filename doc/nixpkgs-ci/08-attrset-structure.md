# Resulting Attrset Structure

This document describes the structure of the attribute set produced by
nixpkgs release files for Hydra consumption.

## Basic Structure

After evaluation, release.nix produces an attrset like:

```nix
{
  # Non-package special jobs
  tarball = <drv>;
  release-checks = <drv>;
  manual = <drv>;
  metrics = <drv>;

  # Aggregate gates
  unstable = <aggregate-drv>;
  darwin-tested = <aggregate-drv>;

  # Bootstrap tools by platform
  stdenvBootstrapTools = {
    "aarch64-unknown-linux-gnu" = { build = <drv>; test = <drv>; };
    "x86_64-unknown-linux-gnu" = { build = <drv>; test = <drv>; };
    "arm64-apple-darwin" = { build = <drv>; test = <drv>; };
    # ...
  };

  # Package jobs: attrpath.system = drv
  hello = {
    x86_64-linux = <drv>;
    aarch64-linux = <drv>;
    x86_64-darwin = <drv>;
    aarch64-darwin = <drv>;
  };

  # Nested package sets
  pythonPackages = {
    requests = {
      x86_64-linux = <drv>;
      aarch64-linux = <drv>;
    };
    numpy = {
      x86_64-linux = <drv>;
      # ...
    };
  };

  # Haskell multi-compiler
  haskell = {
    compiler = {
      ghc948 = { x86_64-linux = <drv>; ... };
      ghc9122 = { x86_64-linux = <drv>; ... };
    };
    packages = {
      ghc96 = {
        haskell-language-server = { x86_64-linux = <drv>; ... };
      };
      ghc98 = { ... };
    };
  };

  # Alternative toolchains
  pkgsLLVM = { stdenv = { x86_64-linux = <drv>; aarch64-linux = <drv>; }; };
  pkgsMusl = { stdenv = { x86_64-linux = <drv>; aarch64-linux = <drv>; }; };

  # Tests
  tests = {
    lib-tests = { x86_64-linux = <drv>; };
    cc-wrapper = {
      default = { x86_64-linux = <drv>; ... };
      llvmPackages.clang = { x86_64-linux = <drv>; ... };
    };
  };
}
```

## Hydra Job Naming

Hydra flattens the attrset to job names using dot notation:

| Attrpath | Hydra Job Name |
|----------|----------------|
| `hello.x86_64-linux` | `hello.x86_64-linux` |
| `pythonPackages.requests.x86_64-linux` | `pythonPackages.requests.x86_64-linux` |
| `haskell.compiler.ghc948.x86_64-linux` | `haskell.compiler.ghc948.x86_64-linux` |

## Job Types

### Regular Package Jobs

Structure: `attrpath.system = derivation`

```nix
hello.x86_64-linux = derivation {
  name = "hello-2.12.1";
  system = "x86_64-linux";
  meta = { ... };
  outputs = [ "out" ];
  # When scrubJobs = true, only essential attrs remain
};
```

### Aggregate Jobs

Structure: `aggregate = derivation with _hydraAggregate = true`

```nix
unstable = derivation {
  name = "nixpkgs-24.11pre...";
  _hydraAggregate = true;
  constituents = [ <drv> <drv> ... ];
  meta.description = "Release-critical builds for the Nixpkgs unstable channel";
};
```

### Channel Jobs

Structure: `channel = derivation with isHydraChannel = true`

```nix
channel = derivation {
  name = "nixos-24.11pre...";
  meta.isHydraChannel = true;
  # Contains nixexprs.tar.xz
};
```

## NixOS release.nix Structure

```nix
{
  channel = <channel-drv>;

  # Documentation
  manualHTML = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
  manualEpub = { ... };
  options = <drv>;  # Only x86_64-linux

  # Installation media
  iso_minimal = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
  iso_graphical = { x86_64-linux = <drv>; aarch64-linux = <drv>; };

  # SD images (ARM only)
  sd_image = {
    armv6l-linux = <drv>;
    armv7l-linux = <drv>;
    aarch64-linux = <drv>;
  };

  # Cloud images
  amazonImage = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
  proxmoxImage = { x86_64-linux = <drv>; };

  # Network boot
  netboot = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
  kexec = { x86_64-linux = <drv>; aarch64-linux = <drv>; };

  # Tests (very large)
  tests = {
    login = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
    openssh = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
    gnome = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
    # ... hundreds of tests
    allDrivers = {
      login = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
      # ... test drivers (faster to eval)
    };
  };

  # Closure size tracking
  closures = {
    smallContainer = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
    kde = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
    gnome = { x86_64-linux = <drv>; aarch64-linux = <drv>; };
  };
}
```

## attrNamesOnly Mode

When `attrNamesOnly = true`, the structure changes for CI optimization:

```nix
# Normal mode
hello = {
  x86_64-linux = <drv>;
  aarch64-linux = <drv>;
};

# attrNamesOnly mode
hello = <drv>;  # Just one representative derivation
```

This reduces memory usage dramatically for attrpath enumeration.

## recurseForDerivations

Package sets use this marker to indicate Hydra/nix-env should recurse:

```nix
pythonPackages = {
  recurseForDerivations = true;  # Essential marker
  requests = { x86_64-linux = <drv>; };
  numpy = { x86_64-linux = <drv>; };
};
```

Without this, nested package sets would be ignored.

## recurseForRelease

Similar to `recurseForDerivations`, but specifically for release evaluation:

```nix
somePackageSet = {
  recurseForRelease = true;
  # ...
};
```

Checked in `release-lib.nix`:
```nix
recursiveMapPackages = f:
  mapAttrs (name: value:
    if isDerivation value then f value
    else if value.recurseForDerivations or false
         || value.recurseForRelease or false then
      recursiveMapPackages f value
    else [ ]
  );
```

## Platform Filtering Result

The `packagePlatforms` function produces:

```nix
# Input: pkgs attrset
# Output: attrset of platform lists

{
  hello = [ "aarch64-linux" "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
  pythonPackages = {
    requests = [ "aarch64-linux" "x86_64-linux" ];
    # numpy might be linux-only
    numpy = [ "aarch64-linux" "x86_64-linux" ];
  };
  linuxPackages = {
    perf = [ "aarch64-linux" "x86_64-linux" ];  # Linux only
  };
}
```

Then `mapTestOn` transforms this to derivations by system.

## Stripped Derivation Attributes

When `scrubJobs = true`, `hydraJob` strips derivations to:

```nix
{
  # Preserved
  name = "hello-2.12.1";
  system = "x86_64-linux";
  outputs = [ "out" ];
  out = {
    outPath = "/nix/store/...";
    drvPath = "/nix/store/....drv";
  };
  meta = {
    # All meta preserved
    description = "...";
    license = lib.licenses.gpl3Plus;
    platforms = [ ... ];
    maintainers = [ ... ];
    # ...
  };

  # For aggregates only
  _hydraAggregate = true;
  constituents = [ ... ];

  # STRIPPED (not present):
  # - src
  # - buildInputs
  # - nativeBuildInputs
  # - buildPhase
  # - installPhase
  # - All other build-time attributes
}
```

This dramatically reduces memory during evaluation.
