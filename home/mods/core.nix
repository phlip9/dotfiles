# Core tools that should be installed on every system
{
  config,
  lib,
  pkgs,
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
    home.packages = with pkgs; [
      # GNU core utils
      coreutils
      file
      which
      gnused
      gawk

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
      # TODO: figure out fzf setup on new machine
      # fzf

      # network
      bind.dnsutils # `dig`, `nslookup`, `delv`, `nsupdate`
      iperf
      socat
      netcat-gnu # `nc`
      curl
      wget
    ];

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
