#!/usr/bin/env bash
set -euo pipefail

# Run all nvim tests by default, or narrow to a relative path under nvim/.
if [ "$#" -eq 0 ]; then
  nix build -f . -L --no-link phlipPkgs.nvim.tests.nvim-test
elif [ "$#" -eq 1 ]; then
  nix build -f pkgs/nvim/nvim-test-runner.nix -L --no-link \
    --argstr filter "$1"
else
  echo "usage: just nvim-test [nvim-relative-test-path]" >&2
  exit 1
fi
