# Core tools that should be installed on every system
{
  config,
  lib,
  pkgs,
  # TODO(phlip9): rename inputs -> sources
  inputs,
  ...
}:
{
  options.home.dotfilesDir = lib.mkOption {
    type = lib.types.str;
    default = "${config.home.homeDirectory}/dev/dotfiles";
    description = ''
      Path to the dotfiles repo. Used to make symlinks from various files and
      directories in the `$HOME` dir into the repo dir.
    '';
  };

  config = {
    nix = {
      # Normally, when e run a command like `nix run nixpkgs#hello` or
      # `nix shell nixpkgs#diffoscope`, nix will download the latest nixpkgs
      # repo, package, and runtime libs for this quick ephemeral bin/shell.
      # This whole thing is pretty wasteful.
      #
      # With this setting, nix will instead use the same `nixpkgs` version as the
      # one we're using for our home-manager setup, which saves time and disk
      # space.
      registry = {
        nixpkgs.flake = inputs.nixpkgs;
        home-manager.flake = inputs.home-manager;
      };

      # Let <nixpkgs>, <home-manager>, etc... work with our pinned sources
      # instead of the imperative `nix-channel` thing.
      channels = inputs;
    };

    home.packages = [
      # GNU core utils
      pkgs.coreutils
      pkgs.file
      pkgs.findutils
      pkgs.gawk
      pkgs.gnused
      pkgs.parallel
      pkgs.which

      # archives
      pkgs.gnutar
      pkgs.unzip
      pkgs.xz
      pkgs.zip
      pkgs.zstd

      # dev utils
      pkgs.bat
      pkgs.dotenvy
      pkgs.dua
      pkgs.fastmod
      pkgs.fd
      pkgs.hexyl
      pkgs.hyperfine
      pkgs.jq
      pkgs.just
      pkgs.npins
      pkgs.patchelf
      pkgs.ripgrep

      # network
      pkgs.dnsutils # `dig`, `nslookup`, `delv`, `nsupdate`
      pkgs.curl
      pkgs.iperf
      pkgs.netcat-gnu # `nc`
      pkgs.socat
      pkgs.wget
    ];

    # Use consistent man across platforms
    programs.man = {
      enable = true;

      # re-index man pages so `apropos`, `man -k`, and friends work.
      # adds a few seconds to home-manager rebuild time.
      generateCaches = false;
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
