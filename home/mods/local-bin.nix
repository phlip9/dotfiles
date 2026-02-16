# random scripts we link into ~/.local/bin from dotfiles/bin
{
  pkgs,
  config,
  ...
}:
let
  dotfilesDir = config.home.dotfilesDir;
  hostPlatform = pkgs.stdenv.hostPlatform;
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
in
{
  home.file = {
    ".local/bin/hms".source = mkOutOfStoreSymlink "${dotfilesDir}/bin/hms";
    ".local/bin/nor".source = mkOutOfStoreSymlink "${dotfilesDir}/bin/nor";
    ".local/bin/picolispfmt".source =
      mkOutOfStoreSymlink "${dotfilesDir}/bin/picolispfmt";
    ".local/bin/signal-china".source =
      mkOutOfStoreSymlink "${dotfilesDir}/bin/signa-china";
    ".local/bin/traceexec.d" = {
      enable = hostPlatform.isDarwin;
      source = mkOutOfStoreSymlink "${dotfilesDir}/bin/traceexec.d";
    };
  };
}
