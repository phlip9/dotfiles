# phliptop-mbp - macOS laptop home-manager config
{
  phlipPkgs,
  pkgs,
  ...
}:
{
  home.username = "phlip9";
  home.homeDirectory = "/Users/phlip9";

  # Preserve state compatibility across Home Manager upgrades.
  home.stateVersion = "25.11";

  imports = [
    ./mods/core.nix

    ./mods/alacritty.nix
    ./mods/bash.nix
    ./mods/ctags.nix
    # ./mods/direnv.nix
    ./mods/fonts.nix
    ./mods/fzf.nix
    # ./mods/gdb.nix
    ./mods/gh.nix
    ./mods/git/default.nix
    # ./mods/github-agent.nix
    ./mods/gpg-agent.nix
    ./mods/gpg.nix
    # ./mods/hol-light-dev.nix
    ./mods/inputrc.nix
    # ./mods/jdk.nix
    ./mods/jujutsu.nix
    ./mods/lexe.nix
    ./mods/local-bin.nix
    # ./mods/lsyncd.nix
    # ./mods/mpv.nix
    # ./mods/nethack.nix
    # ./mods/niri.nix
    ./mods/nix-sources.nix
    # ./mods/noctalia.nix
    ./mods/nvim/default.nix
    ./mods/postgres.nix
    ./mods/python.nix
    ./mods/ssh.nix
    ./mods/ssh-agent.nix
    ./mods/tmux.nix
  ];

  home.packages = [
    pkgs.age-plugin-yubikey
    pkgs.htop
    pkgs.tailscale

    phlipPkgs.antigravity-cli
    phlipPkgs.claude-code
    phlipPkgs.codex

    # Serve Darwin builds for sauna on demand.
    # see: doc/DARWIN-BUILDER.md
    phlipPkgs.darwin-builder-serve
  ];

  programs.home-manager.enable = true;

  # --- Services --- #

  services.postgres = {
    enable = true;
    ensureDatabases = [
      "lexe-dev"
      "ldk-vss-server-dev"
    ];
  };
}
