# omnara1 - Hetzner bare metal dev server home config
{
  # a reference to the home-manager config object this fn outputs
  # config,
  # nixpkgs
  pkgs,
  # ../pkgs/default.nix
  phlipPkgs,
  # nixpkgs.lib
  # lib,
  # # flake inputs passed in via `extraSpecialArgs`
  # inputs,
  ...
}:
{
  # Easily search through home-manager options:
  # <https://mipmip.github.io/home-manager-option-search>

  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "phlip9";
  home.homeDirectory = "/home/phlip9";

  # This dev machine uses its own GitHub account.
  programs.git.settings = {
    user.name = "lexe-agent (phlip9)";
    user.email = "admin+github.agent@lexe.app";
    # Auto-append co-author trailer to all commits so they show phlip9 as a
    # contributor. Works with `git commit -m` unlike commit.template.
    hooks.prepare-commit-msg = ./omnara1/prepare-commit-msg;
  };

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05"; # Please read the comment before changing.

  imports = [
    ./mods/core.nix

    # ./mods/alacritty.nix
    ./mods/bash.nix
    # ./mods/claude.nix
    # ./mods/ctags.nix
    # ./mods/direnv.nix
    # ./mods/fonts.nix
    ./mods/fzf.nix
    ./mods/gdb.nix
    ./mods/gh.nix
    ./mods/git.nix
    ./mods/gpg.nix
    ./mods/gpg-agent.nix
    ./mods/inputrc.nix
    # ./mods/jdk.nix
    ./mods/lexe.nix
    ./mods/local-bin.nix
    # ./mods/lsyncd.nix
    # ./mods/mpv.nix
    # ./mods/niri.nix
    # ./mods/noctalia.nix
    ./mods/nvim/default.nix
    ./mods/omnara.nix
    ./mods/postgres.nix
    ./mods/python.nix
    ./mods/ssh.nix
    # ./mods/ssh-agent.nix
    ./mods/tmux.nix
  ];

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    pkgs.htop
    pkgs.lm_sensors

    pkgs.clangStdenv.cc
    pkgs.gh
    pkgs.protobuf
    pkgs.rustup
    pkgs.uv
    pkgs.htmlq

    # claude - AI cli
    phlipPkgs.claude-code

    # codex - AI cli
    phlipPkgs.codex
  ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
