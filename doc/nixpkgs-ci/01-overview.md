# Nixpkgs Hydra CI Evaluation Architecture

This document series provides a comprehensive analysis of how nixpkgs
structures its Nix code for Hydra CI evaluation and builds.

## Document Index

1. [Overview](01-overview.md) - This document
2. [Release Entrypoints](02-release-entrypoints.md) - Main release.nix files
3. [Release Library](03-release-lib.md) - Core library functions
4. [Platform Filtering](04-platform-filtering.md) - How platforms are matched
5. [Eval Error Handling](05-eval-error-handling.md) - checkMeta and failures
6. [Job Aggregation](06-job-aggregation.md) - aggregate and channel jobs
7. [CI Eval Infrastructure](07-ci-eval.md) - GitHub Actions eval system
8. [Resulting Attrset Structure](08-attrset-structure.md) - Final job layout
9. [Passthru Tests](09-passthru-tests.md) - passthru.tests handling

## High-Level Architecture

The nixpkgs CI evaluation system is centered around several key components:

```
                         ┌─────────────────────────────┐
                         │  Hydra Jobset Definition    │
                         │  (declarative.nix in Hydra) │
                         └─────────────┬───────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                        Release Entrypoints                           │
│  ┌────────────────┐  ┌─────────────────┐  ┌────────────────────────┐ │
│  │ release.nix    │  │ nixos/release.  │  │ release-{cross,haskell │ │
│  │ (Nixpkgs)      │  │ nix (NixOS)     │  │  ,python,...}.nix      │ │
│  └───────┬────────┘  └────────┬────────┘  └───────────┬────────────┘ │
└──────────┼────────────────────┼───────────────────────┼──────────────┘
           │                    │                       │
           └────────────────────┼───────────────────────┘
                                ▼
                    ┌───────────────────────┐
                    │    release-lib.nix    │
                    │  (core abstractions)  │
                    └───────────┬───────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐     ┌─────────────────┐     ┌─────────────────────┐
│  mapTestOn    │     │  packagePlatforms│    │   hydraJob          │
│  (platform    │     │  (extract meta.  │    │   (strip attrs for  │
│   mapping)    │     │   platforms)     │    │    memory savings)  │
└───────────────┘     └─────────────────┘     └─────────────────────┘
```

## Supported Systems

Defined in `ci/supportedSystems.json`:

```json
[
  "aarch64-linux",
  "aarch64-darwin",
  "x86_64-linux",
  "x86_64-darwin"
]
```

All release files consume this centralized configuration to ensure consistency.

## Key Files (relative to nixpkgs root)

| File | Purpose |
|------|---------|
| `pkgs/top-level/release.nix` | Main Nixpkgs jobset |
| `pkgs/top-level/release-lib.nix` | Core platform mapping functions |
| `nixos/release.nix` | NixOS tests, images, and artifacts |
| `nixos/release-combined.nix` | Combined NixOS+Nixpkgs channel |
| `pkgs/top-level/release-cross.nix` | Cross-compilation smoke tests |
| `pkgs/top-level/release-haskell.nix` | Haskell ecosystem builds |
| `lib/customisation.nix` | `hydraJob` function definition |
| `pkgs/build-support/release/default.nix` | `aggregate` and `channel` |
| `pkgs/stdenv/generic/check-meta.nix` | Package validity checks |
| `ci/eval/*.nix` | GitHub Actions evaluation infra |

## Evaluation Flow

1. **Hydra triggers evaluation** of a release file (e.g., `release.nix`)

2. **release-lib.nix is imported** with `supportedSystems` configuration

3. **Package sets are memoized** per system via `mkPkgsFor` to prevent
   re-evaluation

4. **`packagePlatforms`** recursively walks the package tree, extracting
   `meta.hydraPlatforms` or computing from `meta.platforms - meta.badPlatforms`

5. **`mapTestOn`** transforms the platform lists into actual derivation
   references by system, producing `{ pkgName.system = drv; ... }`

6. **`hydraJob`** (when `scrubJobs = true`) strips non-essential attributes
   from derivations to reduce memory usage during evaluation

7. **Aggregate jobs** combine multiple derivations into single "gating" jobs
   that must all pass

8. **Hydra builds** the resulting derivation tree, scheduling jobs per system

## Memory Optimization

The evaluation uses several techniques to minimize memory:

```nix
# From release-lib.nix - memoization prevents duplicate evaluations
mkPkgsFor = crossSystem:
  let
    pkgs_x86_64_linux = packageSet' { system = "x86_64-linux"; };
    pkgs_aarch64_linux = packageSet' { system = "aarch64-linux"; };
    # ... etc
  in
  system:
    if system == "x86_64-linux" then pkgs_x86_64_linux
    # ... pattern matching to return memoized values
```

```nix
# From lib/customisation.nix - hydraJob strips non-essential attrs
hydraJob = drv:
  let
    commonAttrs = {
      inherit (drv) name system meta;
      inherit outputs;
    };
    # ... only essential attributes preserved
  in
  if drv == null then null else deepSeq drv' drv';
```

## Configuration Flags

Key flags passed to release files:

| Flag | Purpose |
|------|---------|
| `scrubJobs` | Strip derivation attributes to save memory |
| `attrNamesOnly` | Return only attr names, not derivations (for CI chunking) |
| `officialRelease` | Enable release-specific behavior |
| `supportedSystems` | Override default platform list |
| `nixpkgsArgs.config.allowUnfree` | Control unfree package evaluation |
| `nixpkgsArgs.config.inHydra` | Enable Hydra-specific error handling |

## References

- [Hydra Manual](https://hydra.nixos.org/build/196107287/download/1/hydra/index.html)
- [nixpkgs Hydra Instance](https://hydra.nixos.org/project/nixpkgs)
- [NixOS Hydra Instance](https://hydra.nixos.org/project/nixos)
