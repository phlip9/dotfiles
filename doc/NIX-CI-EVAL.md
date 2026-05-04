# phlip9/dotfiles Nix CI eval

`nix/ci/default.nix` defines the Hydra-style job tree used by buildbot-nix.
It is a non-flake eval entrypoint; `flake.nix` is only a thin wrapper exposing
the tree at `checks.x86_64-linux`.

## Job tree

- `phlipPkgs`: packages from `pkgs/`, built for matching supported systems.
- `phlipPkgs.tests`: `passthru.tests` from `phlipPkgs`.
- `phlipPkgsNixos`: NixOS-only packages from `nixos/pkgs/`, filtered to linux
  systems before package `meta.platforms` matching.
- `phlipPkgsNixos.tests`: `passthru.tests` from `phlipPkgsNixos`.
- `nixosConfigs`: NixOS system toplevel builds.
- `nixosTests`: NixOS VM tests, built on `buildSystem`.
- `homeConfigs`: home-manager activation packages, selected by explicit
  host-to-system mapping.

Non-derivation attrsets that should be traversed set `recurseForDerivations`.
Package jobs are wrapped with `lib.hydraJob` by default to scrub large drv attrs
during eval.

## Platform handling

CI supports `supportedSystems`, defaulting to:

```nix
[
  "x86_64-linux"
  "aarch64-darwin"
]
```

`phlipPkgs` uses the full supported set. `phlipPkgsNixos` first narrows that set
to linux systems, then applies each package's `meta.hydraPlatforms`,
`meta.platforms`, and `meta.badPlatforms`. Packages without explicit platform
metadata therefore only emit linux jobs in the NixOS package subtree.

NixOS configs and tests use `buildSystem`, currently `x86_64-linux`.

## Eval model

The CI entrypoint imports the repo top-level `default.nix` once per supported
system and memoizes those package sets. That keeps package and test job
construction from re-importing nixpkgs per package.

Nixpkgs is imported with CI-oriented config:

- `allowUnsupportedSystem = true`
- `checkMeta = true`
- `inHydra = true`
- repo unfree policy from `nix/config-unfree.nix`
- fatal eval issues abort; non-fatal issues throw so the job is marked failed

## Local checks

```bash
# Eval a specific NixOS-only package job.
nix eval -f ./nix/ci/default.nix \
  phlipPkgsNixos.github-agent-authd.x86_64-linux.name

# Build a specific NixOS-only package job.
nix build -f ./nix/ci/default.nix \
  phlipPkgsNixos.github-agent-authd.x86_64-linux

# Build all phlipPkgs passthru.tests.
nix build -f ./nix/ci/default.nix phlipPkgs.tests

# Build a NixOS VM test.
nix build -f ./nix/ci/default.nix nixosTests.github-webhook.x86_64-linux
```
