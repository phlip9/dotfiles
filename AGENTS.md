# @phlip9's dotfiles

- stack: lix, home-manager, niri, noctalia-shell, neovim, tmux, bash, alacritty.
- nix based, non-flake default.nix.
- home-manager manages non-GUI user dotfiles on all Linux and macOS machines.
- neovim configured w/ lua.


## high-level layout (non-exhaustive)

- config/bash/bashrc (bash settings, aliases, some completions)
- config/bash/tmux.conf
- bin/ (helper scripts, symlinked into $PATH)
- default.nix (top-level nix, all packages, home-manager + nixos configs)
- doc/ (architecture, ops run-books, research, guides, tutorials)
- home/ (home-manager machine configs)
- home/mods/ (custom home-manager modules)
- home/mods/nvim/default.nix (nvim plugins, tools)
- justfile (common tasks)
- nix/ (common nix libs)
- nixos/ (nixos machine configs)
- nixos/mods/ (nixos configurable modules)
- nixos/profiles/ (high-level, not-configurable, use-case focused NixOS configs)
- nvim/init.lua (neovim config)
- nvim/lua/ (personal neovim lua plugins and modules)
- nvim/lua/test/ (tests for my neovim lua plugins)
- pkgs/ (`phlipPkgs` personal nix packages)


## communication

- high signal, low noise. high density, compact info.
- assume high context reader.
- avoid superfluous prose, politeness, emoji, etc. filler wastes my time.
- drop: articles (a/an/the), filler (just/really/basically/actually/simply),
  pleasantries (sure/certainly/of course/happy to), hedging, em-dashes,
  en-dashes. fragments ok.
- abbreviate: db, auth, config, param, req, resp, fn, impl, w/, b/c, ...
- one word when one word enough.
- short synonyms: big > extensive, fix > "implement a solution for".
- use exact technical terms.
- plan: clarify requirements ruthlessly. if fuzzy, vague, or ambiguous, then
  you MUST ask before go-ahead.
- less abstract and verbose, more concrete and succinct.
- lead changes with intent. justify with precision.


## style

- general: 80-column width, except for urls or similar.
- nix: all external inputs pinned. all packages, home-manager configs, nixos
  configs, etc accessible from top-level default.nix. avoid overlays.
- commits: use ':' namespace in commit titles, ex:
  - `nvim: add baleia.nvim to colorize ANSI escape sequences`
  - `nixos: manually add nautilus file chooser back into systemPackages`
  - `nix: don't need flakes anymore`
  - `phlipdesk: enable ssh-agent systemd service`
  - `firefox: add BetterTTV extension`
  - updates use nixpkgs convention, ex: `omnara: 0.13.4 -> 0.13.5` or `omnara:
    init at 0.13.4`.
- commits: rarely add a commit message body, unless change is complex or
  non-obvious.
- commits: ABSOLUTELY NEVER add "Co-Authored-By: " trailer.
- structure changes and commits for reviewability. prefer small, focused
  commits that are easy to review. bulk changes or refactors should be split
  out from primary changes into own commit(s) for fast review.
- changes MUST fit coherently in the codebase. avoid unnecessary vendoring.
- comments: every non-trivial function/struct/module/type needs at least a
  short comment. include short "guide post" comments above logic blocks.
  non-trivial items need longer comments; more complex or surprising, then
  better documented. future readers should not need to guess why.
- names: almost always avoid single-character variable names.
- nix package names should be snake-case. ex: `github-agent-authd`.


## nixos

- machine: nixos/phlipnixos/default.nix - main desktop
- machine: nixos/omnara1/default.nix - Hetzner dev machine
- priorities: reliable, beautiful, secure, performant, minimalist.
- full-disk encryption, single-user install, auto-login, secure boot.

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
- `nvim-ci`: `nvim-fmt`, `nvim-lint`, `nvim-test` format/lint/test neovim
  config and modules
- `nvim-print-base-runtime-path` print base nvim installation's runtime path
- `nvim-print-my-plugins-dir` print my installed non-default nvim plugins dir

before presenting changes, run the relevant lint/format/test commands and fix
any issues.


## nix

this repo does NOT use flakes. do not use e.g. `nix build .#samply` syntax, it
will not work. use `-f .` to point to `default.nix` in this repo.

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
- `phlipPkgs`: personal package set (`./pkgs/default.nix`)
- `pkgsNixos`: nixpkgs unstable package set from `phlipnixos` (almost same as `pkgsUnstable`)
- `pkgsUnstable`: nixpkgs unstable package set
- `pkgs`: nixpkgs stable package set
- `sources`: npins pinned external sources (nixpkgs, home-manager, ...)


## nvim

### lua

- use `just nvim-fmt` to format all *.lua files.
- use `require_local("module")` to import modules from `nvim/lua/`.
- prefer stateless modules.
- platform-specific code only handles Linux and macOS. never care about
  Windows.
- if module not needed at startup, only `require` when actually used. make
  keymaps lazy. reduce startup time.
- when wrapping a fn, preserve return contract. lua multi-return silently
  truncates: `local x = f()` drops second value.
- never use bare `pcall(fn)`. always capture and log: `local ok, err =
  pcall(fn); if not ok then vim.notify(...) end`.
- error handling is not optional.
- `vim.schedule_wrap` any `vim.system` callbacks touching nvim APIs
  (`vim.notify`, `nvim_*`, etc).
- don't mutate caller's opts/config table. copy first then mutate.
- 0-indexed APIs (extmarks, `nvim_win_set_cursor`, ...): if input can be 0,
  avoid underflow when converting from 1-indexed w/ `math.max(0, idx-1)`.

### lua tests

- tests in `nvim/lua/test/*_spec.lua`.
- tests use Plenary/Busted. run via `just nvim-test`.
- `just nvim-test` runs full `nvim/lua/test` in nix sandbox.
- `just nvim-test <path>` runs specific file/dir relative to `nvim/` (ex: `just
  nvim-test lua/test/my_mod_spec.lua`).
- make tests deterministic: use fixed dates, explicit buffer contents, temp
  dirs/repos, never depend on user's local env or editor state.
- clean up nvim and filesystem state created by test: temp buffers, windows,
  autocmds, files, dirs, any mutated globals/options.
- prefer narrow unit tests for pure helpers.
- ensure e2e integration test coverage for top-level features.
- target test coverage at integration layer, not just helpers. bugs live in
  glue code.
- mirror existing spec style: top-level file comment, short helper comments,
  `local eq = assert.are.same`, and `describe()` / `it()` structure.


## PRs

create PRs using `gh`:

```bash
$ gh pr create --repo phlip9/dotfiles --title "..." --reviewer phlip9 \
  --body-file <(cat << 'EOF'
...
EOF
)
```

- only allowed to create branches/PRs off `agent/**` branches.
- always use `--body-file` over `--body`.
- always request review from `phlip9`.
- never put raw markdown text in shell commands.
- only use e.g. #5 in PR title or body if referring to another PR.
- if PR already exists and body needs updating, use: `gh pr edit --repo
  phlip9/dotfiles <pr-number> --body-file <(...)`.
