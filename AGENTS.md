# @phlip9's dotfiles

- stack: nix, home-manager, neovim, tmux, bash, alacritty
- nix based. non-flake default.nix
- home-manager manages ~/ on all Linux and macOS machines
- neovim configured with lua

## high-level layout

- bashrc (bash settings, aliases, some completions)
- bin/ (helper scripts symlinked into $PATH)
- default.nix (top-level nix, all packages, home-manager and nixos configs)
- home/ (home-manager machine configs)
- home/mods/ (custom home-manager modules)
- home/mods/nvim/default.nix (nvim plugins and tool dependencies)
- justfile (just recipies for common tasks)
- nix/ (common nix libs)
- nixos/ (nixos machine configs)
- nixos/mods/ (nixos modules)
- nvim/init.lua (neovim config)
- nvim/lua/ (personal neovim lua plugins and modules)
- pkgs/ (custom nix packages)
- tmux.conf (tmux config)

## commands

- `just just-fmt` format justfile
- `just bash-lint` lint bash scripts
- `just nix-fmt` format nix files
- `just nix-lint` lint nix files
- `just nvim-print-my-plugins-dir` print my installed non-default nvim plugins dir
- `just nvim-print-base-runtime-path` print base nvim installation's runtime path

- ex: `nix build -f . samply` build `samply` package in `pkgs/samply.nix`
- ex: `nix build -f . pkgs.lego` build `lego` package in from nixpkgs
- ex: `nix build -f . homeConfigs.phlipdesk.activationPackage` build `phlipdesk` home-manager config
- ex: `nix eval -f . homeConfigs.phlipdesk.config.systemd.user.services.nix-ssh-agent.Service.ExecStart`
- ex: `nix build -f . nixosConfigs.phlipnixos.config.system.build.toplevel`
- ex: `nix eval -f . nixosConfigs.phlipnixos.config.system.nixos.version`

## style

- general: stick to 80-column width, except for urls or other annoying cases.
- nix: all external inputs are pinned by default. all packages, home-manager
  configs, nixos configs, etc are accesible from the top-level default.nix for
  ease of use and debugging. avoid overlays.
