{ pkgs, ... }:
let
  hostPlatform = pkgs.hostPlatform;
in
{
  home.packages = [
    pkgs.source-code-pro
  ];

  fonts.fontconfig = {
    enable = hostPlatform.isLinux;
  };
}
