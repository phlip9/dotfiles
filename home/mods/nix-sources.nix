# Pin Nix source lookups to the sources used by Home Manager.
{
  config,
  lib,
  sources,
  ...
}:
{
  nix = {
    # This module owns the complete search path on standalone hosts.
    keepOldNixPath = false;

    # Reuse Home Manager's nixpkgs for ephemeral flake commands instead of
    # downloading another revision.
    registry = {
      nixpkgs.flake = sources.nixpkgs;
      home-manager.flake = sources.home-manager;
    };

    # Provide legacy angle-bracket lookups without imperative Nix channels.
    channels = {
      inherit (sources) nixpkgs home-manager;
    };
  };

  # Keep generic Linux user services on the same declarative search path as
  # shells, replacing Home Manager's stock user-channel path.
  systemd.user.sessionVariables = lib.mkIf config.targets.genericLinux.enable {
    NIX_PATH = lib.mkForce (lib.concatStringsSep ":" config.nix.nixPath);
  };
}
