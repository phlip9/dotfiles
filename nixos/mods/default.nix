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

      # systemd 262 `user@.service` only skips the memory pressure watch, so
      # PID 1 hands the user manager a locked CPU/IO pressure watch via env.
      # The user manager then can't apply its own default threshold and warns
      # "Failed to adjust io pressure threshold" on every start/reexec.
      # TODO(phlip9): drop once nixpkgs' systemd includes upstream b6cdaf4a3d
      # ("units: let systemd user/capsule manage its own CPU/I/O pressure
      # handling").
      systemd.services."user@".serviceConfig = {
        CPUPressureWatch = "skip";
        IOPressureWatch = "skip";
      };
    }
  )

  (sources.sops-nix + "/modules/sops/default.nix")
  ./darwin-builder.nix
  ./etc-hosts.nix
  ./github-agent-authd.nix
  ./github-webhook.nix
  ./nix-cache.nix
  ./o11y
  (sources.paseo + "/nix/module.nix")
  ./paseo.nix
  ./perf.nix
  ./phlippkgs.nix
  ./postgres.nix

  # Upstream takes its default package as an import arg, which can't see our
  # module args. ./rbitcoin.nix sets `services.rbitcoin.package` instead.
  (import (sources.rbitcoin + "/nix/modules/rbitcoin.nix") {
    defaultPackage = throw "services.rbitcoin.package: unset";
  })
  ./rbitcoin.nix

  ./xremap.nix

  # nixbot CI module + its dependencies (nixbot and niks3)
  (sources.nixbot + "/nixosModules/nixbot.nix")
  (sources.niks3 + "/nix/nixosModules/niks3.nix")
  ./nixbot-ci.nix
]
