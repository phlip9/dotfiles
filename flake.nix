# Minimal flake wrapper for buildbot-nix CI.
#
# This flake has no inputs - everything comes from default.nix which uses npins.
# buildbot-nix evaluates `.#checks` to discover build targets.
#
# See: docs/buildbot-nix-ci.md
# See: nixos/mods/buildbot-ci.nix
{
  description = "phlip9's dotfiles";

  # No inputs - we use npins in default.nix
  inputs = { };

  outputs =
    { self }:
    {
      # Expose checks for buildbot-nix to evaluate
      checks = {
        x86_64-linux =
          let
            dotfiles = import ./default.nix { localSystem = "x86_64-linux"; };
          in
          {
            # NixOS system builds
            omnara1 = dotfiles.nixosConfigs.omnara1.config.system.build.toplevel;

            # Package tests
            nvim-test = dotfiles.phlipPkgs.nvim.tests.nvim-test;
          };

        aarch64-darwin =
          let
            dotfiles = import ./default.nix { localSystem = "aarch64-darwin"; };
          in
          {
            # Package tests
            nvim-test = dotfiles.phlipPkgs.nvim.tests.nvim-test;
          };
      };
    };
}
