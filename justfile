# list all available commands
default:
    just --list

# --- top-level --- #

ci: just-ci bash-ci nix-ci go-ci nvim-ci

fmt: just-fmt nix-fmt go-fmt

lint: bash-lint nix-lint nvim-lint

# --- just --- #

just-ci: just-fmt

just-fmt:
    just --fmt --unstable

# --- bash --- #

bash-ci: bash-lint

bash-lint:
    nix shell -f . pkgs.shellcheck pkgs.fd --command \
        fd --type file '^.*(hms|nos|bashrc|\.sh|\.bash)$' \
            --exec shellcheck {}

# --- nix --- #

nix-ci: nix-fmt nix-lint

nix-fmt:
    nix shell -f . phlipPkgs.nixfmt pkgs.fd --command \
        fd --extension "nix" --exec nixfmt --width 80 {}

nix-lint:
    nix shell -f . pkgs.nil --command \
        fd --extension "nix" --exec nil diagnostics

# Update phlipPkgs package(s) with updateScript
phlippkgs-update pkg="":
    nix-shell pkgs/update.nix {{ if pkg != "" { "--argstr package " + pkg } else { "" } }}

# --- go --- #

go-ci: go-fmt go-test

go-fmt:
    nix shell -f . pkgs.go pkgs.fd --command \
        fd --type file '^.*\.go$' --exec-batch gofmt -w {}

go-test *args:
    nix shell -f . pkgs.go --command \
        bash -c "cd pkgs/github-webhook && mkdir -p /tmp/go-cache && GOCACHE=/tmp/go-cache GO111MODULE=off go test"

# --- neovim --- #

nvim-ci: nvim-lint nvim-test

nvim-lint:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    ~/.local/share/lua-language-server/bin/lua-language-server \
        --check nvim/ \
        --checklevel Hint \
        --configpath "$PWD/.luarc.json" \
        --logpath "$TMPDIR/log" \
        --metapath "$TMPDIR/meta"

nvim-test *args:
    nvim --headless \
        -c "PlenaryBustedDirectory nvim/lua/test {nvim_cmd = '$(which nvim)'}" \
        {{ args }}

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

# --- deployment --- #

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
        --exec bash -c 'yes | sops updatekeys {}'

sops-test-fixtures *args:
    SOPS_AGE_KEY_FILE=./nixos/tests/fixtures/keys.txt sops {{ args }}

sops-test-fixtures-edit:
    just sops-test-fixtures \
        --config nixos/tests/fixtures/.sops.yaml \
        nixos/tests/fixtures/secrets.yaml

ssh-updatekeys:
    curl https://github.com/phlip9.keys > nix/phlip9.keys
