# Configure phlip9's nix cache as an extra substituter.
{ lib, config, ... }:

let
  cfg = config.phlip9.nix-cache;
in
{
  options.phlip9.nix-cache = {
    enable = lib.mkEnableOption "phlip9's nix cache";
  };

  config.nix.settings = lib.mkIf cfg.enable {
    extra-substituters = [ "https://cache.phlip9.com" ];
    extra-trusted-public-keys = [
      "cache.phlip9.com-1:XKElS8qFXxVXcXIGFjRkGpyxiernJzHeQhMJ59VUdf4="
    ];
  };
}
