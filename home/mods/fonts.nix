{ pkgs, ... }:
let
  hostPlatform = pkgs.stdenv.hostPlatform;
in
{
  home.packages = [
    pkgs.source-code-pro
  ];

  fonts.fontconfig = {
    enable = hostPlatform.isLinux;
  };
}
