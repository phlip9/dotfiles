# This list of NixOS modules is always imported in our NixOS configs, unlike
# nixos/profiles/*.nix. They are generally usually "off" by default, with
# an "enable" option and other options to turn on and configure them.
{ sources }:

[
  (sources.disko + "/module.nix")
  (
    { lib, ... }:
    {
      disko.enableConfig = lib.mkDefault false;

      # silence a random warning
      # TODO(phlip9): periodically remove this and see if the issue persists
      boot.zfs.forceImportRoot = false;
    }
  )

  (sources.sops-nix + "/modules/sops/default.nix")
  ./etc-hosts.nix
  ./github-agent-authd.nix
  ./github-webhook.nix
  ./nix-cache.nix
  ./noctalia-shell.nix
  ./o11y.nix
  (sources.paseo + "/nix/module.nix")
  ./paseo.nix
  ./phlippkgs.nix
  ./xremap.nix

  # nixbot CI module + its dependencies (nixbot and niks3)
  (sources.nixbot + "/nixosModules/nixbot.nix")
  (sources.niks3 + "/nix/nixosModules/niks3.nix")
  ./nixbot-ci.nix
]
