# mdadm RAID 0 across two NVMe SSDs (~1.8 TiB unified storage)
#
# Hardware:
# - /dev/nvme0n1 - 894.25 GiB (Toshiba KXD51RUE960G)
# - /dev/nvme1n1 - 894.25 GiB (Toshiba KXD51RUE960G)
{
  disko = {
    enableConfig = true;

    devices = {
      disk = {
        nvme0 = {
          type = "disk";
          device = "/dev/nvme0n1";
          content = {
            type = "gpt";
            partitions = {
              boot = {
                size = "1M";
                type = "EF02"; # for grub MBR
              };
              ESP = {
                size = "2G";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };
              swap = {
                size = "32G";
                content = {
                  type = "swap";
                };
              };
              mdadm = {
                size = "100%";
                content = {
                  type = "mdraid";
                  name = "nixos";
                };
              };
            };
          };
        };
        nvme1 = {
          type = "disk";
          device = "/dev/nvme1n1";
          content = {
            type = "gpt";
            partitions = {
              mdadm = {
                size = "100%";
                content = {
                  type = "mdraid";
                  name = "nixos";
                };
              };
            };
          };
        };
      };
      mdadm = {
        nixos = {
          type = "mdadm";
          level = 0;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
