# CI eval entrypoint
#
# Requirements:
# - Provide a Hydra-style job tree similar to nixpkgs CI, tailored to our
#   dotfiles repo layout and constraints.
# - Compose jobs from: phlipPkgs (pkgs/), nixosConfigs (nixos/),
#   nixosTests (nixos/tests/), and homeConfigs (home/).
# - Include phlipPkgs passthru.tests under a phlipPkgs.tests subtree.
# - Use meta.hydraPlatforms / meta.platforms / meta.badPlatforms for platform
#   filtering, and mark all non-drv attrsets with recurseForDerivations.
# - Evaluate efficiently: instantiate nixpkgs once per system, and avoid
#   re-evaluating per package/platform.
# - Use nixpkgs CI-style eval handling (inHydra, checkMeta, handleEvalIssue).
# - Support a small set of target systems, and a single build system for NixOS
#   configs/tests.
# - Be non-flake and compatible with `nix build -f . ci` style entrypoints.
#
# How this module works:
# - Construct a per-system repo evaluation (repoFor) using our top-level
#   default.nix, memoized by supportedSystems to reduce eval time.
# - Uses nix/ci/lib.nix to map phlipPkgs -> platform lists and to wrap
#   derivations with hydraJob when scrubJobs is enabled.
# - Builds a job tree:
#     phlipPkgs.${pkg}.${system} = drv
#     phlipPkgs.tests.${pkg}.${test}.${system} = drv
#     nixosConfigs.${host} = drv
#     nixosTests.${test}.${system} = drv
#     homeConfigs.${host} = drv
#   and sets recurseForDerivations at every non-drv attrset level.
#
# Integration with the repo:
# - Uses the top-level default.nix for consistent access to pkgs, phlipPkgs,
#   homeConfigs, and nixosConfigs, respecting our pinned nixpkgs and unfree
#   policy.
# - NixOS tests are provided by nixos/tests (from pkgsUnstable) and are built
#   only on the buildSystem (currently x86_64-linux).
# - Home-manager configs are explicitly mapped to their host systems to avoid
#   relying on implicit metadata that we don't currently encode.
{
  # Systems we eval and emit jobs for
  supportedSystems ? [
    "x86_64-linux"
    "aarch64-darwin"
  ],
  # System used to build NixOS configs/tests
  buildSystem ? "x86_64-linux",
  # Whether to scrub derivations for eval memory use
  scrubJobs ? true,
}:
let
  # Pinned nixpkgs via npins
  sources = import ../../npins;
  nixpkgs = sources.nixpkgs;
  lib = import (nixpkgs + "/lib");

  # Optional hydraJob wrapper to strip drv attrs when requested.
  ciJob = if scrubJobs then lib.hydraJob else lib.id;

  # Given a list of 'meta.platforms'-style patterns, return the sublist of
  # `supportedSystems` containing systems that matches at least one of the given
  # patterns.
  #
  # This is written in a funny way so that we only elaborate the systems once.
  supportedMatches =
    let
      supportedPlatforms = builtins.map (
        system: lib.systems.elaborate { inherit system; }
      ) supportedSystems;
    in
    metaPatterns:
    let
      anyMatch =
        platform: builtins.any (lib.meta.platformMatch platform) metaPatterns;
      matchingPlatforms = builtins.filter anyMatch supportedPlatforms;
    in
    builtins.map ({ system, ... }: system) matchingPlatforms;

  # Generate attributes for all systems matching the patterns.
  forMatchingSystems = metaPatterns: lib.genAttrs (supportedMatches metaPatterns);

  # Recursively map over a package set honoring recurseFor* flags.
  recursiveMapPackages =
    f:
    builtins.mapAttrs (
      name: value:
      if lib.isDerivation value then
        f value
      else if
        value.recurseForDerivations or false || value.recurseForRelease or false
      then
        recursiveMapPackages f value
      else
        [ ]
    );

  # Extract supported platforms from meta, honoring hydraPlatforms,
  # badPlatforms, and platforms.
  getPlatforms =
    drv:
    lib.intersectLists supportedSystems (
      drv.meta.hydraPlatforms or (lib.subtractLists (drv.meta.badPlatforms or [ ]) (
        drv.meta.platforms or supportedSystems
      ))
    );

  # Map a package set to meta.platform lists.
  mkPackagePlatforms = recursiveMapPackages getPlatforms;

  # nixpkgs config tuned for CI eval
  nixpkgsConfig = (import ../config-unfree.nix) // {
    allowUnsupportedSystem = true;
    checkMeta = true;
    inHydra = true;

    # Match nixpkgs CI behavior: abort on fatal meta errors, throw on known
    # non-fatal reasons to mark eval-failed jobs.
    handleEvalIssue =
      reason: errormsg:
      let
        fatalErrors = [
          "unknown-meta"
          "broken-outputs"
        ];

        nonFatalErrors = [
          "blocklisted"
          "broken"
          "insecure"
          "non-source"
          "unfree"
          "unsupported"
        ];
      in
      if builtins.elem reason fatalErrors then
        abort errormsg
      else if builtins.elem reason nonFatalErrors then
        throw reason
      else
        true;
  };

  # Memoize top-level repo eval per system to avoid repeated nixpkgs evals.
  repoFor =
    let
      mkRepo =
        system:
        import ../.. {
          localSystem = system;
          inherit sources;
          args = {
            localSystem = system;
            config = nixpkgsConfig;
          };
        };

      repos = lib.genAttrs supportedSystems mkRepo;
    in
    system: repos.${system} or (abort "unsupported system: ${system}");

  # Use currentSystem for meta inspection when possible.
  evalSystem =
    let
      # builtins.currentSystem is unavailable in pure flake eval
      current = builtins.currentSystem or null;
    in
    if current != null && lib.elem current supportedSystems then
      current
    else
      builtins.elemAt supportedSystems 0;

  # Base package set for platform discovery.
  phlipPkgsEval = (repoFor evalSystem).phlipPkgs;
  # Per-system package set for job construction.
  phlipPkgsFor = system: (repoFor system).phlipPkgs;

  # Map phlipPkgs to platform lists, dropping the pkgs marker attr.
  packagePlatforms = builtins.removeAttrs (mkPackagePlatforms phlipPkgsEval) [
    "_type"
  ];

  # Build jobs across matching systems for a package function.
  testOn =
    metaPatterns: f:
    forMatchingSystems metaPatterns (system: ciJob (f (phlipPkgsFor system)));

  # Convert packagePlatforms into { attrpath.system = drv; } jobs.
  mapTestOn = lib.mapAttrsRecursive (
    path: metaPatterns: testOn metaPatterns (pkgs: lib.getAttrFromPath path pkgs)
  );

  # Primary phlipPkgs job tree, trimmed of empty nodes.
  phlipPkgsJobs = lib.filterAttrs (_: v: v != { }) (mapTestOn packagePlatforms);

  # Wrap a nested test attrset into per-system derivation leaves.
  wrapDerivations =
    system:
    let
      recurse =
        value:
        if lib.isDerivation value then
          { "${system}" = ciJob value; }
        else if builtins.isAttrs value then
          let
            mapped = builtins.mapAttrs (_: v: recurse v) value;
            cleaned = lib.filterAttrs (_: v: v != { }) mapped;
          in
          if cleaned == { } then { } else cleaned // { recurseForDerivations = true; }
        else
          { };
    in
    recurse;

  # Collect passthru.tests for one package across its supported systems.
  testsForPackage =
    name: platforms:
    let
      perSystem = builtins.map (
        system:
        let
          pkg = (phlipPkgsFor system).${name};
          tests = pkg.passthru.tests or { };
        in
        wrapDerivations system tests
      ) platforms;

      merged = builtins.foldl' lib.recursiveUpdate { } perSystem;
    in
    if merged == { } then { } else merged // { recurseForDerivations = true; };

  # Add passthru.tests under phlipPkgs.tests
  phlipPkgsTests =
    let
      testsByPkg = lib.mapAttrs testsForPackage packagePlatforms;
      pruned = lib.filterAttrs (_: v: v != { }) testsByPkg;
    in
    if pruned == { } then { } else pruned // { recurseForDerivations = true; };

  # Top-level NixOS system build jobs
  nixosConfigs = builtins.mapAttrs (
    _: cfg: ciJob cfg.config.system.build.toplevel
  ) (repoFor buildSystem).nixosConfigs;

  # NixOS test jobs (linux only, from unstable pkgs)
  nixosTests = wrapDerivations buildSystem (repoFor buildSystem).nixosTests;

  # Explicit host->system mapping for home-manager configs
  # TODO(phlip9): annotate in each home config instead
  homeConfigSystems = {
    omnara1 = "x86_64-linux";
    phlipdesk = "x86_64-linux";
    phlipnixos = "x86_64-linux";
    phliptop-mbp = "aarch64-darwin";
    phliptop-nitro = "x86_64-linux";
  };

  # Home-manager activation packages per host system.
  homeConfigs = builtins.mapAttrs (
    name: system: ciJob (repoFor system).homeConfigs.${name}.activationPackage
  ) homeConfigSystems;
in
# Final job tree
{
  phlipPkgs = phlipPkgsJobs // {
    tests = phlipPkgsTests;
    recurseForDerivations = true;
  };
  nixosConfigs = nixosConfigs;
  nixosTests = nixosTests;
  homeConfigs = homeConfigs;

  _dbg = {
    inherit
      packagePlatforms
      supportedMatches
      phlipPkgsTests
      ;
  };
}
