# omnara1 - Hetzner bare metal dev server
#
# Hardware:
# - 2x 894 GiB NVMe SSDs in RAID 0
# - IPv4: 95.217.195.225
# - IPv6: 2a01:4f9:4a:52de::2
{
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware.nix
    ./disko-config.nix
    ../profiles/server.nix
  ];

  system.stateVersion = "26.05";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Bootloader
  boot.loader = {
    grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
  };

  # Use latest kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Silence mdadm warning about missing MAILADDR or PROGRAM
  boot.swraid.mdadmConf = "PROGRAM ${pkgs.coreutils}/bin/true";

  # Hostname
  networking.hostName = "omnara1";
  networking.domain = "phlip9.com";

  # Use systemd networkd
  systemd.network.enable = true;
  networking.useNetworkd = true;

  # Static network configuration (Hetzner)
  networking.wireless.enable = false;
  networking.useDHCP = false;
  networking.interfaces.eno1 = {
    ipv4.addresses = [
      {
        address = "95.217.195.225";
        prefixLength = 26;
      }
    ];
    ipv6.addresses = [
      {
        address = "2a01:4f9:4a:52de::2";
        prefixLength = 64;
      }
    ];
  };
  networking.defaultGateway = {
    address = "95.217.195.193";
    interface = "eno1";
  };
  networking.defaultGateway6 = {
    address = "fe80::1";
    interface = "eno1";
  };
  networking.nameservers = [
    "185.12.64.1"
    "185.12.64.2"
    "2a01:4ff:ff00::add:1"
    "2a01:4ff:ff00::add:2"
  ];
  services.timesyncd.servers = [
    "ntp1.hetzner.de"
    "ntp2.hetzner.com"
    "ntp3.hetzner.net"
  ];

  # users and groups are static and must be configured via nix
  users.mutableUsers = false;

  # user
  users.users.phlip9 = {
    isNormalUser = true;
    description = "Philip Kannegaard Hayes";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIP/8j7BMuNsn+aXTjm3LP8mDR8q/GylbrkGVBn1PBrwhAAAABHNzaDo= phlip9-5ci-fips"
    ];

    # Enable "linger" so that systemd will start the user service and all
    # `default.target`-triggered user services automatically on boot.
    linger = true;
  };

  # Run non-NixOS binaries
  programs.nix-ld = {
    enable = true;
    libraries = [
    ];
  };
}
