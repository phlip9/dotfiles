# list all available commands
default:
    just --list

fmt: just-fmt nix-fmt

just-fmt:
    just --fmt --unstable

nix-fmt:
    nix shell -f . phlipPkgs.nixfmt pkgs.fd --command \
        fd --extension "nix" --exec nixfmt --width 80 {}

lint: bash-lint flake-lint nix-lint

bash-lint:
    nix shell -f . pkgs.shellcheck pkgs.fd --command \
        fd --type file '^.*(hms|bashrc|\.sh)$' \
            --exclude pkgs/claude-code \
            --exec shellcheck {}

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
