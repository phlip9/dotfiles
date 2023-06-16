# list all available commands
default:
    just --list

fmt: just-fmt nix-fmt

just-fmt:
    just --fmt --unstable

nix-fmt:
    nix fmt

lint: bash-lint flake-lint nix-lint

bash-lint:
    shellcheck bashrc

flake-lint:
    nix flake check

nix-lint:
    fd --extension "nix" . | xargs --replace=FILE nil diagnostics FILE
