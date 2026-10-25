{
  # be careful not to pass `pkgs` eval to normal NixOS system evals
  pkgs,
  sources,
}:
let
  nixpkgs = sources.nixos-unstable;

  # be careful not to pass `pkgs` eval to normal NixOS system evals. they should
  # control their own package set.
  nixosSystem =
    args:
    import (nixpkgs + "/nixos/lib/eval-config.nix") (
      {
        lib = import (nixpkgs + "/lib");
        system = null;
        modules = args.modules ++ [
          { _module.args.sources = sources; }
        ];
        extraModules = import ./mods { inherit sources; };
      }
      // (builtins.removeAttrs args [ "modules" ])
    );
in
{
  # NixOS graphical installer ISO configuration
  nixos-iso = nixosSystem {
    modules = [
      (
        {
          lib,
          config,
          modulesPath,
          ...
        }:
        {
          imports = [
            (modulesPath + "/misc/nixpkgs/read-only.nix")
            (modulesPath + "/installer/cd-dvd/installation-cd-graphical-combined.nix")
          ];

          # force external, read-only pkgs for iso
          nixpkgs = {
            pkgs = pkgs;
            overlays = lib.mkForce pkgs.overlays;
            flake.source = nixpkgs.outPath;
          };

          # enable `nix` command and flakes support
          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];

          # TODO(phlip9): support booting off multios-usb stick. nixpkgs
          # dropped scripted stage-1, which implemented `findiso=` and grub
          # `loopback.cfg` ISO-in-file boot. Needs a systemd initrd unit that
          # loop-mounts `findiso=<path>` so `/dev/disk/by-label/<volumeID>`
          # appears. Fix next time we run a NixOS ISO off multios-usb.
          # boot.initrd = {
          #   systemd.enable = false;
          #   availableKernelModules = [ "exfat" ];
          #   kernelModules = [ "exfat" ];
          #   supportedFilesystems = [ "exfat" ];
          # };

          # zfs is incompatible with the latest kernel and not needed here.
          boot.supportedFilesystems.zfs = lib.mkForce false;
        }
      )
    ];
  };

  # NixOS headless installer ISO configuration
  nixos-iso-headless = nixosSystem {
    modules = [
      (
        {
          lib,
          config,
          modulesPath,
          ...
        }:
        {
          imports = [
            (modulesPath + "/misc/nixpkgs/read-only.nix")
            (modulesPath + "/installer/cd-dvd/installation-cd-minimal-new-kernel.nix")
          ];

          # force external, read-only pkgs for iso
          nixpkgs = {
            pkgs = pkgs;
            overlays = lib.mkForce pkgs.overlays;
            flake.source = nixpkgs.outPath;
          };

          # enable `nix` command and flakes support
          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];

          # TODO(phlip9): support booting off multios-usb stick. nixpkgs
          # dropped scripted stage-1, which implemented `findiso=` and grub
          # `loopback.cfg` ISO-in-file boot. Needs a systemd initrd unit that
          # loop-mounts `findiso=<path>` so `/dev/disk/by-label/<volumeID>`
          # appears. Fix next time we run a NixOS ISO off multios-usb.
          # boot.initrd = {
          #   systemd.enable = false;
          #   availableKernelModules = [ "exfat" ];
          #   kernelModules = [ "exfat" ];
          #   supportedFilesystems = [ "exfat" ];
          # };

          # zfs is incompatible with the latest kernel and not needed here.
          boot.supportedFilesystems.zfs = lib.mkForce false;
        }
      )
    ];
  };

  # phlipdesk NixOS desktop
  phlipdesk = nixosSystem {
    modules = [ ./phlipdesk/default.nix ];
  };

  # sauna - Hetzner bare metal server
  sauna = nixosSystem {
    modules = [ ./sauna/default.nix ];
  };
}
