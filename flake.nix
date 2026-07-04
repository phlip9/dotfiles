# Minimal flake wrapper for nixbot CI.
#
# This flake has no inputs - everything comes from default.nix which uses npins.
# nixbot evaluates `.#checks` to discover build targets.
#
# See: doc/nixbot-ci.md
# See: nixos/mods/nixbot-ci.nix
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
