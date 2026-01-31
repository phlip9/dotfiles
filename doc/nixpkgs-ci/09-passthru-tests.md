# Passthru Tests

This document covers how `passthru.tests` is handled in nixpkgs CI.

## Overview

`passthru.tests` is a convention for associating test derivations with
packages. These tests verify the package works correctly but are evaluated
separately from the main package build.

## Definition

From `doc/stdenv/passthru.chapter.md`:

```nix
stdenv.mkDerivation {
  pname = "my-package";
  # ...

  passthru.tests = {
    basic = runCommand "test-my-package" { } ''
      ${my-package}/bin/my-program --version
      touch $out
    '';

    # NixOS VM tests
    nixos-integration = nixosTests.myPackage;
  };
}
```

## CI Behavior

### Hydra

**Hydra does NOT build `passthru.tests` by default.**

From the documentation:
> The Nixpkgs systems for continuous integration Hydra and nixpkgs-review
> don't build these derivations by default.

`passthru.tests` are not included in the release.nix job tree because
`packagePlatforms` only looks at derivations themselves, not their passthru:

```nix
# From release-lib.nix
recursiveMapPackages = f:
  mapAttrs (name: value:
    if isDerivation value then
      f value  # Only processes the derivation, not passthru
    else if value.recurseForDerivations or false then
      recursiveMapPackages f value
    else
      [ ]
  );
```

### ofBorg

**ofBorg DOES build `passthru.tests` for changed packages.**

From the documentation:
> ofborg only builds them when evaluating pull requests for that particular
> package, or when manually instructed.

When a package is modified in a PR, ofBorg:
1. Identifies the changed package
2. Builds the package itself
3. Also builds `passthru.tests` for that package

### nixpkgs-review

Similarly, `nixpkgs-review` builds `passthru.tests` for packages it's testing.

## NixOS Tests as passthru.tests

A common pattern is linking NixOS VM tests:

```nix
{ nixosTests, ... }:
stdenv.mkDerivation {
  pname = "opensmtpd";
  # ...
  passthru.tests = {
    basic-functionality = nixosTests.opensmtpd;
  };
}
```

The `nixosTests` argument provides access to all tests from
`nixos/tests/all-tests.nix`.

## all-tests.nix Structure

**File:** `nixos/tests/all-tests.nix`

This file discovers and wraps all NixOS tests:

```nix
{ system, pkgs, callTest }:
let
  discoverTests = val:
    if isAttrs val then
      if (val ? test) then
        callTest val
      else
        mapAttrs (n: s: if n == "passthru" then s else discoverTests s) val
    else if isFunction val then
      discoverTests (val { inherit system pkgs; })
    else
      val;

  # Helper for legacy test format
  handleTest = path: args:
    discoverTests (import path ({ inherit system pkgs; } // args));
in
{
  # Tests are listed here
  login = runTest ./login.nix;
  openssh = runTest ./openssh.nix;
  # ...
}
```

Note the `passthru` handling:
```nix
mapAttrs (n: s: if n == "passthru" then s else discoverTests s) val
```

This **skips** recursing into `passthru` attributes, preventing
`passthru.tests` from being accidentally included in the NixOS test suite.

## Test Platform Handling

Tests from `passthru.tests` respect the platform of the parent package:

```nix
# Package only on Linux
meta.platforms = lib.platforms.linux;

passthru.tests = {
  # This test would only make sense on Linux
  basic = runCommand "test" { } "...";
};
```

For NixOS tests linked via `nixosTests`, they're naturally Linux-only since
they run in VMs.

## Empty Tests for Unsupported Platforms

From `nixos/tests/all-tests.nix`:

```nix
# The tests not supported by `system` will be replaced with `{}`, so that
# `passthru.tests` can contain links to those without breaking on architectures
# where said tests are unsupported.
```

This means:
```nix
passthru.tests = {
  # On aarch64-darwin, this might evaluate to {}
  # instead of failing
  nixos-integration = nixosTests.myPackage;
};
```

## Explicit Test Jobs

Some release files DO include specific tests:

```nix
# From release-haskell.nix
(mapTestOn {
  tests.haskell = packagePlatforms pkgs.tests.haskell;
  nixosTests = {
    agda = packagePlatforms pkgs.nixosTests.agda;
    inherit (packagePlatforms pkgs.nixosTests) kmonad xmonad;
  };
})
```

These are explicitly added to the jobset, separate from `passthru.tests`.

## Building passthru.tests Manually

```bash
# Build all tests for a package
nix-build -A myPackage.tests

# Build a specific test
nix-build -A myPackage.tests.basic

# Using nix build
nix build .#myPackage.tests.basic
```

## versionCheckHook vs passthru.tests

The documentation recommends `versionCheckHook` over `passthru.tests` for
simple version checks:

```nix
# Preferred: runs during installCheckPhase
nativeInstallCheckInputs = [ versionCheckHook ];

# Alternative: as a passthru test
passthru.tests.version = testers.testVersion { package = my-package; };
```

Advantages of `versionCheckHook`:
- Runs automatically during build
- Failure blocks the build
- No extra CI configuration needed

## Meta Attribute Validation

The `check-meta.nix` validates test structure:

```nix
metaTypes = {
  # ...
  tests = {
    name = "test";
    verify = x:
      x == { }  # Empty attrset (unsupported platform)
      || (isDerivation x && x ? meta.timeout);
  };
  # ...
};
```

Note: This validates `meta.tests`, not `passthru.tests`. The `meta.tests`
attribute is largely deprecated in favor of `passthru.tests`.

## Summary

| CI System | Builds passthru.tests? | When? |
|-----------|------------------------|-------|
| Hydra | No | Never by default |
| ofBorg | Yes | For changed packages in PRs |
| nixpkgs-review | Yes | For reviewed packages |
| Manual | Yes | When explicitly requested |

The key insight is that `passthru.tests` provides **on-demand testing** rather
than **always-on CI testing**. This keeps Hydra build load manageable while
still allowing comprehensive testing when packages change.
