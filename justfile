# list all available commands
default:
    just --list

fmt: just-fmt nix-fmt

just-fmt:
    just --fmt --unstable

nix-fmt:
    nix shell -f . phlipPkgs.nixfmt pkgs.fd --command \
        fd --extension "nix" --exec nixfmt --width 80 {}

lint: bash-lint nix-lint

bash-lint:
    nix shell -f . pkgs.shellcheck pkgs.fd --command \
        fd --type file '^.*(hms|nos|bashrc|\.sh)$' \
            --exclude pkgs/claude-code \
            --exec shellcheck {}

nix-lint:
    nix shell -f . pkgs.nil --command \
        fd --extension "nix" --exec nil diagnostics

nvim-update-extra-plugins:
    nix shell nixpkgs#vimPluginsUpdater --command \
        vim-plugins-updater \
            --input-names ./home/mods/nvim/nvim-extra-plugins.csv \
            --out ./home/mods/nvim/nvim-extra-plugins.generated.nix \
            --no-commit \
            --debug DEBUG \
            --nixpkgs ../nixpkgs \
            update
    just nix-fmt

nvim-print-my-plugins-dir:
    nvim --headless \
        -c 'lua print(vim.opt.runtimepath:get()[1] .. "/pack/myNeovimPackages/start")' \
        -c 'qa!' \
        2>&1 1>/dev/null

nvim-print-base-runtime-dir:
    readlink -f "$(dirname "$(readlink -f "$(which nvim)")")/../share/nvim/runtime"
