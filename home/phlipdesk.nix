{
  # # a reference to the home-manager config object this fn outputs
  # config,
  # nixpkgs
  pkgs,
  # # nixpkgs.lib
  # lib,
  # # flake inputs passed in via `extraSpecialArgs`
  # inputs,
  ...
}: {
  # Easily search through home-manager options:
  # <https://mipmip.github.io/home-manager-option-search>

  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "phlip9";
  home.homeDirectory = "/home/phlip9";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "23.05"; # Please read the comment before changing.

  imports = [
    ./mods/core.nix

    ./mods/alacritty.nix
    ./mods/bash.nix
    ./mods/ctags.nix
    ./mods/direnv.nix
    ./mods/gh.nix
    ./mods/git.nix
    ./mods/inputrc.nix
    ./mods/local-bin.nix
    ./mods/nvim.nix
    ./mods/python.nix
    ./mods/ssh.nix
    ./mods/tmux.nix
  ];

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    pkgs.htop
    pkgs.lm_sensors

    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # You can also manage environment variables but you will have to manually
  # source
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/phlip9/etc/profile.d/hm-session-vars.sh
  #
  # if you don't want to manage your shell through Home Manager.
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # silence weird error after opening new shell:
  #   ~/.nix-profile/bin/manpath: can't set the locale; make sure $LC_* and $LANG are correct
  programs.man.enable = false;
}
