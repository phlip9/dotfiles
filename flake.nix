# Minimal flake wrapper for buildbot-nix CI.
#
# This flake has no inputs - everything comes from default.nix which uses npins.
# buildbot-nix evaluates `.#checks` to discover build targets.
#
# See: docs/buildbot-nix-ci.md
{
  description = "phlip9's dotfiles";

  # No inputs - we use npins in default.nix
  inputs = { };

  outputs =
    { self }:
    let
      # Import the main default.nix which handles all pinning via npins.
      # Must pass system explicitly since flakes run in pure mode where
      # builtins.currentSystem isn't available.
      dotfiles = import ./default.nix { localSystem = "x86_64-linux"; };
    in
    {
      # Expose checks for buildbot-nix to evaluate
      checks.x86_64-linux = {
        # NixOS system builds
        omnara1 = dotfiles.nixosConfigs.omnara1.config.system.build.toplevel;

        # Package tests
        nvim-test = dotfiles.phlipPkgs.nvim.tests.nvim-test;
      };
    };
}
