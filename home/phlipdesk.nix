# phlipdesk - NixOS desktop home-manager config
{
  pkgs,
  phlipPkgs,
  ...
}:
{
  home.username = "phlip9";
  home.homeDirectory = "/home/phlip9";

  # Preserve state compatibility across Home Manager upgrades.
  home.stateVersion = "25.11";

  imports = [
    ./mods/core.nix

    ./mods/alacritty.nix
    ./mods/bash.nix
    ./mods/ctags.nix
    # ./mods/direnv.nix
    # ./mods/fonts.nix
    ./mods/fzf.nix
    # ./mods/gdb.nix
    # ./mods/gh.nix
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
    ./mods/mpv.nix
    ./mods/nethack.nix
    ./mods/niri.nix
    # ./mods/nix-sources.nix
    ./mods/noctalia.nix
    ./mods/nvim/default.nix
    ./mods/postgres.nix
    ./mods/python.nix
    ./mods/ssh.nix
    ./mods/ssh-agent.nix
    ./mods/tmux.nix
  ];

  home.packages = [
    pkgs.htop
    pkgs.lm_sensors

    phlipPkgs.antigravity-cli
    phlipPkgs.claude-code
    phlipPkgs.codex

    phlipPkgs.timep
    pkgs.clangStdenv.cc
    pkgs.gh
    pkgs.go
    pkgs.htmlq
    pkgs.protobuf
    pkgs.rustup
    pkgs.uv

    phlipPkgs.opentofu
    phlipPkgs.terranix
    pkgs.mutagen
  ];

  programs.home-manager.enable = true;

  # --- Host overrides --- #

  services.postgres = {
    enable = true;
    ensureDatabases = [ "lexe-dev" ];
  };

  # Use the system askpass binary to avoid fontconfig warnings.
  # see: nixos/phlipdesk/default.nix
  services.nix-ssh-agent.ssh-askpass = "/run/current-system/sw/bin/seahorse-ssh-askpass";

  programs.alacritty.fontSize = 11;
}
