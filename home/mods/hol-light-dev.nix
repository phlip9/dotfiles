# HOL-Light dev packages
{ config, pkgs, ... }:
let
  shellHook = ''
    export PKG_CONFIG_PATH="${config.home.profileDirectory}/lib/pkgconfig"
  '';
in
{
  home.packages = with pkgs; [
    opam

    # bubblewrap
    gmp
    gmp.dev
    gnumake
    m4
    opam
    pcre2.dev
    pcre2.out
    perl
    pkg-config
    # which # in core.nix
  ];

  home.sessionVariablesExtra = shellHook;
  programs.bash.initExtra = shellHook;
}
