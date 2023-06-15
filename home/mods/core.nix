# Core tools that should be installed on every system
{pkgs, ...}: {
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

  programs.exa = {
    enable = true;

    # In list view, include a column with each file's git status.
    git = true;
  };
  programs.bash.shellAliases = {
    ks = "exa";
    sl = "exa";
    l = "exa";
    ls = "exa";
    ll = "exa -l";
    la = "exa -a";
    lt = "exa --tree";
    lla = "exa -la";
  };
}
