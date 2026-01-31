# Platform Filtering

This document explains how nixpkgs determines which platforms a package should
be built on for Hydra CI.

## Meta Attributes for Platform Control

### meta.platforms

Specifies platforms where the package is expected to work:

```nix
stdenv.mkDerivation {
  # ...
  meta.platforms = lib.platforms.linux;
  # or
  meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
  # or using platform patterns
  meta.platforms = lib.platforms.unix;
}
```

### meta.badPlatforms

Platforms where the package is known to be broken:

```nix
meta = {
  platforms = lib.platforms.unix;
  badPlatforms = [ "aarch64-darwin" ];  # Broken on Apple Silicon
};
```

### meta.hydraPlatforms

Explicitly override which platforms Hydra builds on. Takes precedence over
`platforms` and `badPlatforms`:

```nix
meta = {
  platforms = lib.platforms.all;
  hydraPlatforms = [ "x86_64-linux" ];  # Only build on x86_64-linux for Hydra
};

# To disable Hydra builds entirely:
meta.hydraPlatforms = [ ];
```

The `lib.meta.dontDistribute` helper sets `hydraPlatforms = []`:

```nix
# From lib/meta.nix
dontDistribute = drv: addMetaAttrs { hydraPlatforms = [ ]; } drv;
```

## Platform Resolution Logic

From `release-lib.nix`:

```nix
getPlatforms = drv:
  drv.meta.hydraPlatforms
    or (subtractLists (drv.meta.badPlatforms or [ ])
                      (drv.meta.platforms or supportedSystems));
```

Resolution order:
1. If `meta.hydraPlatforms` is set, use it directly
2. Otherwise, compute: `meta.platforms - meta.badPlatforms`
3. If `meta.platforms` is unset, default to all `supportedSystems`

## Platform Matching (lib/meta.nix)

### platformMatch

Matches a platform against a pattern:

```nix
platformMatch = platform: elem:
  # Optimization: string comparison for simple platform strings
  if isString elem then
    platform ? system && elem == platform.system
  else
    # For structured platform patterns, use matchAttrs
    matchAttrs (
      if elem ? parsed then elem else { parsed = elem; }
    ) platform;
```

Three pattern types are supported:

1. **Legacy string**: `"x86_64-linux"`
2. **Platform structure pattern**: `{ parsed = { ... }; }`
3. **Parsed field pattern**: `{ cpu = { family = "x86"; }; }`

### availableOn

Check if a package is available on a given platform:

```nix
availableOn = platform: pkg:
  ((!pkg ? meta.platforms) || any (platformMatch platform) pkg.meta.platforms)
  && all (elem: !platformMatch platform elem) (pkg.meta.badPlatforms or [ ]);
```

## Platform Groups (lib/systems/platforms.nix)

Common platform groups used in `meta.platforms`:

```nix
# From lib/platforms.nix (re-exported from lib/systems/platforms.nix)
{
  all = [];  # Empty means "all platforms" in meta.platforms context

  linux = [
    "aarch64-linux"
    "armv5tel-linux"
    "armv6l-linux"
    "armv7a-linux"
    "armv7l-linux"
    "i686-linux"
    "loongarch64-linux"
    "m68k-linux"
    "microblaze-linux"
    "mips64el-linux"
    "mipsel-linux"
    "powerpc64-linux"
    "powerpc64le-linux"
    "riscv32-linux"
    "riscv64-linux"
    "s390-linux"
    "s390x-linux"
    "x86_64-linux"
  ];

  darwin = [ "aarch64-darwin" "x86_64-darwin" ];

  unix = linux ++ darwin ++ freebsd ++ netbsd ++ openbsd;

  # Note: 'none' is different from empty list
  none = [];
}
```

## Structured Platform Patterns

For more precise platform matching:

```nix
# Match all ARM Linux platforms
meta.platforms = [
  { parsed = { kernel = { name = "linux"; }; cpu = { family = "arm"; }; }; }
];

# Using lib.systems.inspect.patterns
meta.platforms = [ lib.systems.inspect.patterns.isLinux ];
```

## Release-Lib Platform Filtering

### supportedMatches

Filters `supportedSystems` to those matching patterns:

```nix
supportedMatches =
  let
    supportedPlatforms = map (system: systems.elaborate { inherit system; })
                             supportedSystems;
  in
  metaPatterns:
    let
      anyMatch = platform: any (meta.platformMatch platform) metaPatterns;
      matchingPlatforms = filter anyMatch supportedPlatforms;
    in
    map ({ system, ... }: system) matchingPlatforms;
```

### forMatchingSystems

Generate job attributes only for matching systems:

```nix
forMatchingSystems = metaPatterns: genAttrs (supportedMatches metaPatterns);

# Example: Build only on x86_64-linux
sdImage = forMatchingSystems [ "x86_64-linux" ] (system: makeSdImage { ... });
```

## Examples

### Package with broad platform support

```nix
stdenv.mkDerivation {
  pname = "hello";
  # ...
  meta.platforms = lib.platforms.unix;
}
# Will build on: x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin
```

### Linux-only package

```nix
meta.platforms = lib.platforms.linux;
# Will build on: x86_64-linux, aarch64-linux (from supportedSystems)
```

### Package with known broken platform

```nix
meta = {
  platforms = lib.platforms.unix;
  badPlatforms = lib.platforms.darwin;  # Broken on macOS
};
# Will build on: x86_64-linux, aarch64-linux
```

### Package only for Hydra cache, not supported

```nix
meta = {
  platforms = [ "x86_64-linux" ];
  hydraPlatforms = [ "x86_64-linux" "aarch64-linux" ];
};
# meta.platforms says only x86_64 is "supported"
# But hydraPlatforms overrides for Hydra to build on both
```

### Disable Hydra builds

```nix
meta = {
  platforms = lib.platforms.linux;
  hydraPlatforms = [ ];  # Don't build on Hydra
};
# or use:
lib.meta.dontDistribute myPackage
```

## check-meta.nix Platform Checks

When `config.checkMeta = true`, packages are validated:

```nix
# From pkgs/stdenv/generic/check-meta.nix
hasUnsupportedPlatform = pkg: !(availableOn hostPlatform pkg);

checkValidity = attrs:
  # ...
  if hasUnsupportedPlatform attrs && !allowUnsupportedSystem then
    {
      reason = "unsupported";
      errormsg = ''
        is not available on the requested hostPlatform:
          hostPlatform.system = "${hostPlatform.system}"
          package.meta.platforms = ${toPretty' (attrs.meta.platforms or [ ])}
          package.meta.badPlatforms = ${toPretty' (attrs.meta.badPlatforms or [ ])}
      '';
      # ...
    }
  # ...
```

This check can be bypassed with:
- `config.allowUnsupportedSystem = true`
- `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` environment variable
