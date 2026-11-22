# Base NixOS module list always imported by every NixOS host (unlike
# nixos/profiles/*.nix). Modules are opt-in (off by default) w/ `enable`
# options, plus small cross-host workarounds below.
{ sources }:

[
  (sources.disko + "/module.nix")
  (
    { lib, ... }:
    {
      disko.enableConfig = lib.mkDefault false;

      # Silence spurious zfs warning.
      # TODO(phlip9): periodically remove this and see if the issue persists
      boot.zfs.forceImportRoot = false;

      # systemd 262 `user@.service` passes locked CPU/IO pressure watches from
      # PID 1, causing "Failed to adjust io pressure threshold" on start/reexec.
      # TODO(phlip9): drop once nixpkgs' systemd has upstream b6cdaf4a3d.
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

  # nixbot CI + deps
  (sources.nixbot + "/nixosModules/nixbot.nix")
  (sources.niks3 + "/nix/nixosModules/niks3.nix")
  ./nixbot-ci.nix
]
