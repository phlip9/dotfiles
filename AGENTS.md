# @phlip9's dotfiles

- stack: lix, home-manager, niri, noctalia-shell, neovim, tmux, bash, alacritty
- nix based, non-flake default.nix
- home-manager manages non-GUI user dotfiles on all Linux and macOS machines
- neovim configured with lua

## high-level layout (non-exhaustive)

- config/bash/bashrc (bash settings, aliases, some completions)
- config/bash/tmux.conf
- bin/ (helper scripts symlinked into $PATH)
- default.nix (top-level nix, all packages, home-manager and nixos configs)
- doc/
- home/ (home-manager machine configs)
- home/mods/ (custom home-manager modules)
- home/mods/nvim/default.nix (nvim plugins and tool dependencies)
- justfile (just recipies for common tasks)
- nix/ (common nix libs)
- nixos/ (nixos machine configs)
- nixos/mods/ (nixos configurable modules)
- nixos/profiles/ (high-level, not-configurable, use-case focused NixOS configs)
- nvim/init.lua (neovim config)
- nvim/lua/ (personal neovim lua plugins and modules)
- nvim/lua/test/ (tests for my neovim lua plugins)
- pkgs/ (`phlipPkgs` personal nix packages)

## communication

- prioritize high signal communication, with high information density
- assume a high context reader
- avoid superfluous prose, politeness, emoji, etc. filler wastes the reviewer's
  time.
- when planning, be ruthless about clarifying requirements. if a request is
  fuzzy, vague, or ambiguous, then you must ask for clarification before
  proceeding.
- anchor abstract descriptions or explanations with concrete and succinct
  examples.
- lead changes with intent and precise justification

## style

- general: stick to 80-column width, except for urls or other annoying cases.
- nix: all external inputs are pinned by default. all packages, home-manager
  configs, nixos configs, etc are accesible from the top-level default.nix for
  ease of use and debugging. avoid overlays.
- commits: use rough ':' namespacing for the commit title, ex:
  - `nvim: add baleia.nvim to colorize ANSI escape sequences`
  - `nixos: manually add nautilus file chooser back into systemPackages`
  - `nix: don't need flakes anymore`
  - `phlipdesk: enable ssh-agent systemd service`
  - `firefox: add BetterTTV extension`
  - updates use nixpkgs convention, ex: `omnara: 0.13.4 -> 0.13.5` or `omnara:
    init at 0.13.4`
- commits: rarely add a commit message body, unless the change is complex or
  non-obvious.
- structure changes and commits for reviewability. prefer small, focused
  commits that are easy to review. bulk changes or refactors should always be
  split out from primary changes into their own commit(s) for easier review.
- comments: every non-trivial function/struct/module/type needs at least a
  short comment. include short "guide post" comments in logic blocks for
  readers. comments for non-trivial items should be longer, according to how
  complex or surprising they are. future readers should not have to guess why
  something was written.
- names: almost always avoid single-character variable names.
- nix package names should be snake-case. ex: `github-agent-authd`.

## nixos

- machine: nixos/phlipnixos/default.nix - main desktop
- machine: nixos/omnara1/default.nix - Hetzner dev machine
- priorities: reliable, beautiful, secure, performant, minimalist
- full-disk encryption, single-user install, auto-login (TODO: secure boot)

- server: nixos/profiles/server.nix
- desktop: nixos/profiles/desktop.nix
- niri: scrolling+tiling wayland compositor
- noctalia-shell: beautiful, minimal wayland desktop built using quickshell+Qt

## just commands (non-exhaustive)

(ex: `just nvim-test`)

- `ci`: `just-ci`, `bash-ci`, ...
- `just-ci`: `just-fmt` format justfile
- `bash-ci`: `bash-lint` shellcheck all *.sh files
- `go-ci`: `go-fmt`, `go-test` gofmt / go test all go packages
- `nix-ci`: `nix-fmt`, `nix-lint`
- `nvim-ci`: `nvim-lint`, `nvim-test` lint/test neovim config and modules
- `nvim-print-base-runtime-path` print base nvim installation's runtime path
- `nvim-print-my-plugins-dir` print my installed non-default nvim plugins dir

after making changes in an area and before presenting the results, run the
relevant lint/format/test commands and fix any issues.

## nix

this repo does NOT use flakes. do not use e.g. `nix build .#samply` syntax, it
will not work. instead, use `-f .` to point to the default.nix in this repo.

to find store paths for our pinned `npins` nix inputs, use e.g.:
`nix eval -f . sources.home-manager.outPath`.

- ex: `nix build -f . samply` build `samply` (alias `phlipPkgs.samply`) package in `pkgs/samply.nix`
- ex: `nix build -f . pkgs.lego` build `lego` package in from stable nixpkgs
- ex: `nix build -f . homeConfigs.phlipdesk.activationPackage` build `phlipdesk` home-manager config
- ex: `nix eval -f . homeConfigs.phlipdesk.config.systemd.user.services.nix-ssh-agent.Service.ExecStart`
- ex: `nix build -f . nixosConfigs.phlipnixos.config.system.build.toplevel`
- ex: `nix eval -f . nixosConfigs.phlipnixos.config.system.nixos.version`
- ex: `nix build -f . nixosTests.github-agent-authd` run NixOS test (only works on Linux)
- ex: `nix build -f . pkgsNixos.lix` build `lix` package from NixOS-machine unstable nixpkgs

### important top-level attrs

- `homeConfigs`: home-manager machine `~/` configs (`./home/<host>.nix`)
- `nixosConfigs`: NixOS machine configs (`./nixos/<host>/default.nix`)
- `nixosTests`: NixOS VM tests (`./nixos/tests/default.nix`)
- `phlipPkgs`: my personal package set (`./pkgs/default.nix`)
- `pkgsNixos`: nixpkgs unstable package set from `phlipnixos` (mostly the same as `pkgsUnstable`)
- `pkgsUnstable`: nixpkgs unstable package set
- `pkgs`: nixpkgs stable package set
- `sources`: npins pinned external sources (nixpkgs, home-manager, etc)

## nvim

### lua

- use `require_local("module")` when importing modules from `nvim/lua/`

## creating PRs

create PRs using the `gh` CLI tool:

```bash
$ gh pr create --repo phlip9/dotfiles --title "..." --body "..."
```

agents are only allowed to create branches and PRs off `agent/**` branches.
