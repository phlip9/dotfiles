# CI eval entrypoint
#
# Requirements:
# - Provide a Hydra-style job tree similar to nixpkgs CI, tailored to our
#   dotfiles repo layout and constraints.
# - Compose jobs from: phlipPkgs (pkgs/), phlipPkgsNixos (nixos/pkgs/),
#   nixosConfigs (nixos/), nixosTests (nixos/tests/), and homeConfigs (home/).
# - Include phlipPkgs passthru.tests under a phlipPkgs.tests subtree.
# - Use meta.hydraPlatforms / meta.platforms / meta.badPlatforms for platform
#   filtering, and mark all non-drv attrsets with recurseForDerivations.
# - Evaluate efficiently: instantiate nixpkgs once per system, and avoid
#   re-evaluating per package/platform.
# - Use nixpkgs CI-style eval handling (inHydra, checkMeta, handleEvalIssue).
# - Support a small set of target systems, and a single build system for NixOS
#   configs/tests.
# - Be non-flake and compatible with `nix build -f ./nix/ci/default.nix`
#   style entrypoints.
#
# How this module works:
# - Construct a per-system repo evaluation (repoFor) using our top-level
#   default.nix, memoized by supportedSystems to reduce eval time.
# - Maps phlipPkgs and phlipPkgsNixos to platform lists and wraps derivations
#   with hydraJob when scrubJobs is enabled.
# - Builds a job tree:
#     phlipPkgs.${pkg}.${system} = drv
#     phlipPkgs.tests.${pkg}.${test}.${system} = drv
#     phlipPkgsNixos.${pkg}.${system} = drv
#     phlipPkgsNixos.tests.${pkg}.${test}.${system} = drv
#     nixosConfigs.${host} = drv
#     nixosTests.${test}.${system} = drv
#     homeConfigs.${host} = drv
#   and sets recurseForDerivations at every non-drv attrset level.
#
# Integration with the repo:
# - Uses the top-level default.nix for consistent access to pkgs, phlipPkgs,
#   phlipPkgsNixos, homeConfigs, and nixosConfigs, respecting our pinned nixpkgs
#   and unfree policy.
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

  supportedPlatforms = builtins.map (
    system: lib.systems.elaborate { inherit system; }
  ) supportedSystems;

  # Restrict NixOS-only packages to Linux systems from the supported set. The
  # package set defaults to nixos-unstable, and CI currently runs on NixOS.
  linuxSystems =
    let
      linuxPlatform = platform: platform.isLinux;
      linuxPlatforms = builtins.filter linuxPlatform supportedPlatforms;
    in
    builtins.map ({ system, ... }: system) linuxPlatforms;

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
  getPlatformsFor =
    systems: drv:
    let
      defaultPlatforms = lib.subtractLists (drv.meta.badPlatforms or [ ]) (
        drv.meta.platforms or systems
      );
    in
    lib.intersectLists systems (drv.meta.hydraPlatforms or defaultPlatforms);

  # Map a package set to meta.platform lists.
  mkPackagePlatformsFor =
    systems:
    let
      getPlatforms = getPlatformsFor systems;
    in
    recursiveMapPackages getPlatforms;

  # nixpkgs config tuned for CI eval
  nixpkgsConfig = (import ../config-unfree.nix) // {
    allowUnsupportedSystem = true;
    checkMeta = true;
    inHydra = true;

    # Based on nixpkgs CI behavior: abort on fatal meta errors, throw on
    # known non-fatal reasons to mark eval-failed jobs.
    # Unlike nixpkgs, we can safely build+cache unfree packages, so
    # "unfree" is not in nonFatalErrors.
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

  # NixOS package platform discovery should use a Linux package set even when
  # eval runs from Darwin.
  evalNixosSystem =
    if linuxSystems == [ ] then
      abort "phlipPkgsNixos CI requires at least one Linux supported system"
    else if lib.elem buildSystem linuxSystems then
      buildSystem
    else
      builtins.elemAt linuxSystems 0;

  # Add recurseForDerivations to non-empty attrsets.
  withRecurseForDerivations =
    attrs:
    if attrs == { } then
      { }
    else
      attrs
      // {
        recurseForDerivations = true;
      };

  # Drop empty nested platform attrs and mark kept nodes recursively.
  prunePlatformTree =
    value:
    if builtins.isAttrs value then
      let
        mapped = builtins.mapAttrs (_: v: prunePlatformTree v) value;
        cleaned = lib.filterAttrs (_: v: v != { }) mapped;
      in
      withRecurseForDerivations cleaned
    else if builtins.isList value then
      if value == [ ] then { } else value
    else
      value;

  # Map a pruned platform tree to drv jobs without traversing generated drvs.
  mapPackagePlatformsToJobs =
    packageSetFor:
    let
      recurse =
        path: value:
        if builtins.isList value then
          lib.genAttrs value (
            system: ciJob (lib.getAttrFromPath path (packageSetFor system))
          )
        else
          builtins.mapAttrs (
            name: child:
            if name == "recurseForDerivations" then
              true
            else
              recurse (path ++ [ name ]) child
          ) value;
    in
    recurse [ ];

  # Map a pruned platform tree to passthru.tests jobs.
  mapPackagePlatformsToTests =
    packageSetFor:
    let
      recurse =
        path: value:
        if builtins.isList value then
          let
            perSystem = builtins.map (
              system:
              let
                pkg = lib.getAttrFromPath path (packageSetFor system);
                tests = pkg.passthru.tests or { };
              in
              wrapDerivations system tests
            ) value;

            merged = builtins.foldl' lib.recursiveUpdate { } perSystem;
          in
          withRecurseForDerivations merged
        else
          let
            attrs = builtins.removeAttrs value [ "recurseForDerivations" ];
            mapChild = name: child: recurse (path ++ [ name ]) child;
            mapped = builtins.mapAttrs mapChild attrs;

            cleaned = lib.filterAttrs (_: child: child != { }) mapped;
          in
          withRecurseForDerivations cleaned;
    in
    recurse [ ];

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
          withRecurseForDerivations cleaned
        else
          { };
    in
    recurse;

  # Build package and passthru.tests jobs for a package set.
  mkPackageJobTree =
    {
      evalPackageSet,
      packageSetFor,
      systems ? supportedSystems,
    }:
    let
      packagePlatforms =
        let
          packagePlatformsRaw =
            builtins.removeAttrs (mkPackagePlatformsFor systems evalPackageSet)
              [ "_type" ];
        in
        prunePlatformTree packagePlatformsRaw;

      # Primary package job tree. Keep drv leaves lazy; do not prune after this.
      packageJobs = mapPackagePlatformsToJobs packageSetFor packagePlatforms;
    in
    packageJobs
    // {
      tests = mapPackagePlatformsToTests packageSetFor packagePlatforms;
      recurseForDerivations = true;
    };

  phlipPkgsJobs = mkPackageJobTree {
    evalPackageSet = (repoFor evalSystem).phlipPkgs;
    packageSetFor = system: (repoFor system).phlipPkgs;
  };

  phlipPkgsNixosJobs = mkPackageJobTree {
    evalPackageSet = (repoFor evalNixosSystem).phlipPkgsNixos;
    packageSetFor = system: (repoFor system).phlipPkgsNixos;
    systems = linuxSystems;
  };

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
  phlipPkgs = phlipPkgsJobs;
  phlipPkgsNixos = phlipPkgsNixosJobs;
  nixosConfigs = nixosConfigs;
  nixosTests = nixosTests;
  homeConfigs = homeConfigs;

  # _dbg = {
  #   inherit
  #     linuxSystems
  #     phlipPkgsJobs
  #     phlipPkgsNixosJobs
  #     ;
  # };
}
