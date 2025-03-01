# random scripts we link into ~/.local/bin from dotfiles/bin
{
  pkgs,
  config,
  ...
}: let
  dotfilesDir = config.home.dotfilesDir;
  hostPlatform = pkgs.hostPlatform;
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
in {
  home.file.".local/bin/picolispfmt".source = mkOutOfStoreSymlink "${dotfilesDir}/bin/picolispfmt";
  home.file.".local/bin/traceexec.d" = {
    enable = hostPlatform.isDarwin;
    source = mkOutOfStoreSymlink "${dotfilesDir}/traceexec.d";
  };
}
