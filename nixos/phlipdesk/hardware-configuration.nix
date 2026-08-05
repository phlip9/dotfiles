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
    "crypt-phlipdisk3" = {
      device = "/dev/disk/by-uuid/74a62a74-f99b-4feb-8d6f-9bd76140b4fb";
      allowDiscards = true; # support TRIM
    };
  };

  fileSystems = {
    # Secondary SSD that stores games, Steam library, large downloads, etc.
    "/mnt/phlipdisk3" = {
      device = "/dev/disk/by-uuid/0b5829aa-d02f-4a0d-9022-32bb83b6a7a2";
      fsType = "ext4";
      options = [
        "noatime"
        "lazytime"
        # Hardening
        "nodev"
        "nosuid"
        # "noexec" # Steam games need to exec
      ];
    };
  };

  # Use a low-priority swapfile. This way zram absorbs memory pressure first,
  # but we've still got headroom for large nix build's with OOMing.
  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024;
      priority = 0;
      # release the whole swap area to the SSD once at swapon. fstrim cannot
      # reach swap blocks.
      discardPolicy = "once";
    }
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
