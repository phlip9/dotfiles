{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "usbhid"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  hardware.i2c.enable = true;

  boot.initrd.luks.devices = {
    "crypt-nixos".device = "/dev/disk/by-uuid/809d56ca-d278-49e7-845b-47f4354ea6a1";
    "crypt-swap".device = "/dev/disk/by-uuid/817d77e0-f4fd-43c2-8307-4ab50caf50d8";
    "crypt-phlipdisk3".device =
      "/dev/disk/by-uuid/74a62a74-f99b-4feb-8d6f-9bd76140b4fb";
    "crypt-ubuntu".device =
      "/dev/disk/by-uuid/bcaf844a-8cfb-4cd4-bff0-10d68b252a3e";
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/65293450-d106-4e73-8617-79477f8be423";
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-uuid/63F1-F7B4";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
    "/mnt/phlipdisk3" = {
      device = "/dev/disk/by-uuid/0b5829aa-d02f-4a0d-9022-32bb83b6a7a2";
      fsType = "ext4";
    };
    "/mnt/ubuntu" = {
      device = "/dev/disk/by-uuid/3a888929-866b-4f92-b4d2-7030c295c441";
      fsType = "ext4";
      options = [ "ro" ];
    };
  };

  swapDevices = [
    { device = "/dev/disk/by-uuid/c0d029d9-610d-4be3-a4ae-e88256dddbb6"; }
  ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp0s31f6.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
