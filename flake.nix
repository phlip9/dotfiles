# Minimal flake wrapper for buildbot-nix CI.
#
# This flake has no inputs - everything comes from default.nix which uses npins.
# buildbot-nix evaluates `.#checks` to discover build targets.
#
# See: doc/buildbot-nix-ci.md
# See: nixos/mods/buildbot-ci.nix
{
  description = "phlip9's dotfiles";

  # No inputs - we use npins
  inputs = { };

  outputs =
    { self }:
    {
      checks.x86_64-linux = import ./nix/ci/default.nix { };
    };
}
