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
    }
  )

  (sources.sops-nix + "/modules/sops/default.nix")
  ./github-agent-authd.nix
  ./github-webhook.nix
  ./nix-cache.nix
  ./noctalia-shell.nix
  ./o11y.nix
  ./phlippkgs.nix
  ./xremap.nix

  # buildbot-ci module + its dependencies (buildbot-nix and niks3)
  (sources.buildbot-nix + "/nixosModules/master.nix")
  (sources.buildbot-nix + "/nixosModules/worker.nix")
  (sources.niks3 + "/nix/nixosModules/niks3.nix")
  ./buildbot-ci.nix
]
