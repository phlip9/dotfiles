# phlip9/dotfiles Nix CI eval plan

Goal: build a Nix CI eval system similar to nixpkgs CI but tailored for our
dotfiles repository structure and needs.

Here's our nixpkgs source tree for looking up nixpkgs references:
/nix/store/5gs5kzcpavjvm25896hp7frik1zzj73c-source

- Add //nix/ci/default.nix, the top-level entrypoint for CI eval
- It imports //default.nix with custom nixpkgs `args` to set `config.inHydra`
  etc.
- Returns a tree of drvs
- Composes jobs from:
  - phlipPkgs (//pkgs/)
    - if a package has `passthru.tests`, add those as nested jobs under
      `phlipPkgs.tests` attr
  - nixosConfigs (//nixos/configs/)
  - nixosTests (//nixos/tests/)
  - homeConfigs (//home/)

- Add minimal //nix/ci/lib.nix for our helper functions. E.g., default
  `supportedSystems` list, our `ciJob` function (similar to nixpkgs'
  `hydraJob`), etc...

- Add `recurseForDerivations` in attrsets to force nix-build to build all
  nested drvs
- At each level of the tree, the containing attrset either holds only drvs or
  has `recurseForDerivations = true;` and holds nested attrsets that eventually
  hold drvs
- Borrow scrubJobs from hydraJob to strip non-essential drv attrs to save
  memory
- Unlike nixpkgs CI, we don't need to first build packagesSystem and then map
  over it; we can directly build the tree of drvs
- Use meta.hydraPlatforms, meta.platforms, and meta.badPlatforms to filter
  systems
- Set nixpkgs args config.inHydra and others like <./nixpkgs-ci/07-ci-eval.md>
  - Reuse our "unfree" policy in //nix/config-unfree.nix
  - We can be more strict than nixpkgs CI since we control all packages and
    have like 1000x fewer packages
  - Handle eval issues similarly to nixpkgs CI

- Ensure we eval efficiently and memoize package sets properly. Package sets
  should only be evaled once per system.

- Current target systems packaged in this repo: x86_64-linux, aarch64-darwin
- Current build systems supported in CI: x86_64-linux

- For local testing convenience, we'll also provide a `ci` attr in //default.nix
  that imports //nix/ci/default.nix. We'll probably need to tweak the args a bit
  so that we can easily build all packages locally for only the current system.
  This entry point would probably set supportedSystems to just
  `[ builtins.currentSystem ]`.
  
  ```
  # Ex: build all CI drvs for the current system:
  $ nix build -f . ci

  # Ex: build a specific phlipPkgs job:
  $ nix build -f . ci.phlipPkgs.nvim.x86_64-linux

  # Ex: build all phlipPkgs passthru.tests:
  $ nix build -f . ci.phlipPkgs.tests
  ```

- Update our thin flake.nix `checks` to use import //nix/ci/default.nix so it
  gets picked up by our buildbot-nix CI

Example attrset structure:

```nix
{
  recurseForDerivations = true;

  # phlipPkgs jobs (pkgs/):
  phlipPkgs = {
    recurseForDerivations = true;

    cataclysm-dda = {
      x86_64-linux = <drv>;
      aarch64-darwin = <drv>;
    };

    noctalia-shell = {
      x86_64-linux = <drv>;
    };

    nvim = {
      x86_64-linux = <drv>;
      aarch64-darwin = <drv>;
    };

    # ... more phlipPkgs

    # passthru.tests jobs for phlipPkgs:
    tests = {
      recurseForDerivations = true;

      nvim = {
        recurseForDerivations = true;

        nvim-test = {
          x86_64-linux = <drv>;
          aarch64-darwin = <drv>;
        };
        version-check = {
          x86_64-linux = <drv>;
          aarch64-darwin = <drv>;
        };
      };
    };
  };

  # NixOS configuration top-level build jobs (nixos/):
  nixosConfigs = {
    phlipnixos = <drv>;
    omnara1 = <drv>;
  };

  # NixOS VM tests (nixos/tests/): linux only
  nixosTests = {
    recurseForDerivations = true;

    github-webhook = {
      x86_64-linux = <drv>;
    };
  };

  # home-manager configurations (home/):
  # - each home config should be annotated with the host system
  # - all of these are x86_64-linux, except phliptop-mbp which is aarch64-darwin
  homeConfigs = {
    omnara1 = <drv>;
    phlipdesk = <drv>;
    phlipnitro = <drv>;
    phlipnixos = <drv>;
    phliptop-mbp = <drv>;
  };
}
```
