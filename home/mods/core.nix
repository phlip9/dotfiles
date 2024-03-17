# Core tools that should be installed on every system
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  options.home.dotfilesDir = lib.mkOption {
    type = lib.types.str;
    default = "${config.home.homeDirectory}/dev/dotfiles";
    description = ''
      Path to the dotfiles repo. Used to make symlinks from various files and
      directories in the `$HOME` dir into the repo dir.
    '';
  };

  config = {
    # Normally, when e run a command like `nix run nixpkgs#hello` or
    # `nix shell nixpkgs#diffoscope`, nix will download the latest nixpkgs repo,
    # package, and runtime libs for this quick ephemeral bin/shell. This whole
    # thing is pretty wasteful.
    #
    # With this setting, nix will instead use the same `nixpkgs` version as the
    # one we're using for our home-manager setup, which saves time and disk
    # space.
    nix.registry.nixpkgs.flake = inputs.nixpkgs;

    home.packages = with pkgs; [
      # GNU core utils
      coreutils
      file
      findutils
      gawk
      gnused
      which

      # archives
      zip
      unzip
      xz
      zstd
      gnutar

      # utils
      bat
      ripgrep
      jq
      fd
      fastmod
      just

      # network
      bind.dnsutils # `dig`, `nslookup`, `delv`, `nsupdate`
      iperf
      socat
      netcat-gnu # `nc`
      curl
      wget
    ];

    # Use consistent man across platforms
    programs.man = {
      enable = true;

      # re-index man pages so `apropos`, `man -k`, and friends work.
      # adds a few seconds to home-manager rebuild time.
      generateCaches = true;
    };

    programs.eza = {
      enable = true;

      # In list view, include a column with each file's git status.
      git = true;
    };

    programs.bash.shellAliases = {
      ks = "eza";
      sl = "eza";
      l = "eza";
      ls = "eza";
      ll = "eza -l";
      la = "eza -a";
      lt = "eza --tree";
      lla = "eza -la";
    };
  };
}
