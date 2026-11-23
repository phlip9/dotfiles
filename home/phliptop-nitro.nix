# phliptop-nitro - non-NixOS Linux laptop home-manager config
{
  config,
  phlipPkgs,
  pkgs,
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
    ./mods/fonts.nix
    ./mods/fzf.nix
    ./mods/gdb.nix
    ./mods/gh.nix
    ./mods/git/default.nix
    # ./mods/github-agent.nix
    ./mods/gpg-agent.nix
    ./mods/gpg.nix
    # ./mods/hol-light-dev.nix
    ./mods/inputrc.nix
    # ./mods/jdk.nix
    ./mods/jujutsu.nix
    # ./mods/lexe.nix
    ./mods/local-bin.nix
    ./mods/lsyncd.nix
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

  # Expose desktop entries and MIME data on non-NixOS Linux.
  targets.genericLinux.enable = true;
  xdg.mime.enable = true;
  xdg.systemDirs.data = [ "${config.home.homeDirectory}/.nix-profile/share" ];

  home.packages = [
    pkgs.htop
    pkgs.lm_sensors
    pkgs.protobuf
    pkgs.liburing.man

    phlipPkgs.codex

    # Lexe dev tools.
    pkgs.lego
    pkgs.josh
    pkgs.rage
    pkgs.toml-cli
    pkgs.uv
    pkgs.age-plugin-yubikey

    pkgs.openssl
    pkgs.openssl.dev
    pkgs.pkg-config
    pkgs.go
  ];

  # Export the profile's pkg-config path in session and Bash setup.
  home.sessionVariablesExtra = ''
    export PKG_CONFIG_PATH=${config.home.profileDirectory}/lib/pkgconfig
  '';
  programs.bash.initExtra = ''
    export PKG_CONFIG_PATH=${config.home.profileDirectory}/lib/pkgconfig
  '';

  programs.home-manager.enable = true;

  # --- Host overrides --- #

  services.postgres = {
    enable = true;
    ensureDatabases = [ "lexe-dev" ];
  };

  programs.alacritty.fontSize = 11;
}
