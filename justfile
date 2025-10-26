# list all available commands
default:
    just --list

fmt: just-fmt nix-fmt

just-fmt:
    just --fmt --unstable

nix-fmt:
    nix shell -f . phlipPkgs.nixfmt pkgs.fd --command \
        fd --extension "nix" --exec nixfmt --check {}

lint: bash-lint flake-lint nix-lint

bash-lint:
    shellcheck bashrc

flake-lint:
    nix flake check

nix-lint:
    nix shell nixpkgs#nil --command \
        fd --extension "nix" --exec nil diagnostics

update-nvim-extra-plugins:
    nix shell nixpkgs#vimPluginsUpdater --command \
        vim-plugins-updater \
            --input-names ./home/mods/nvim/nvim-extra-plugins.csv \
            --out ./home/mods/nvim/nvim-extra-plugins.generated.nix \
            --no-commit \
            --debug DEBUG \
            --nixpkgs ../nixpkgs \
            update
    just nix-fmt
