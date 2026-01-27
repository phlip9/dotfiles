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
            --exclude pkgs/codex \
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

# Boot into Limine UEFI bootloader in a QEMU VM
qemu-bootloader:
    ./bin/qemu-bootloader.sh

deploy-bootstrap cfg:
    #!/usr/bin/env bash
    set -euxo pipefail

    IFS=$'\n' paths=($(nix build -f . --print-out-paths --no-link \
        pkgsUnstable.nixos-anywhere \
        nixosConfigs.{{ cfg }}.config.system.build.diskoScript \
        nixosConfigs.{{ cfg }}.config.system.build.toplevel))

    nixos_anywhere=${paths[0]}
    disko_script=${paths[1]}
    toplevel=${paths[2]}

    "$nixos_anywhere/bin/nixos-anywhere" -L \
        --store-paths "$disko_script" "$toplevel" \
        root@{{ cfg }}

deploy *args:
    nix shell -f . pkgsUnstable.deploy-rs --command \
        deploy -f . {{ args }}

# Make sure all sops secrets files are encrypted for all relevant keys.
sops-updatekeys:
    #!/usr/bin/env bash
    set -euo pipefail

    combined_regex=$(
        yq -r '.creation_rules[].path_regex | select(. != null)' .sops.yaml \
            | sort -u \
            | paste -sd'|'
    )

    [ -z "$combined_regex" ] && exit 0

    fd --type file --full-path --regex "(${combined_regex})" \
        --exec sops updatekeys {}

ssh-updatekeys:
    curl https://github.com/phlip9.keys > nix/phlip9.keys

# Update phlipPkgs package(s) with updateScript
phlippkgs-update pkg="":
    nix-shell pkgs/update.nix {{ if pkg != "" { "--argstr package " + pkg } else { "" } }}
