# Build a sandboxed nvim test derivation with an optional path filter.
#
# Example:
# - just nvim-test lua/test/foo
# - nix build -f pkgs/nvim/nvim-test-runner.nix --argstr filter lua/test/foo
{
  filter ? "",
}:
let
  dotfiles = import ../.. { };
  nvim = dotfiles.phlipPkgs.nvim;
in
nvim.tests.nvim-test.override {
  inherit filter;
}
