{
  disko = {
    enableConfig = true;

    # keep installation mounts separate from existing /mnt filesystems
    # TODO(phlip9): remove after cutover
    rootMountPoint = "/mnt/phlipdesk";

    devices = {
      disk = {
        nvme0 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-Samsung_SSD_970_PRO_512GB_S463NF0K404099B";

          content = {
            type = "gpt";

            partitions = {
              ESP = {
                size = "2G";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                  extraArgs = [
                    # FAT32
                    "-F"
                    "32"
                    # label=BOOT
                    "-n"
                    "BOOT"
                  ];
                };
              };

              root = {
                size = "100%";
                type = "8309"; # Linux LUKS

                content = {
                  type = "luks";
                  name = "crypt-phlipdesk";

                  # prompt twice when the disk is initially formatted
                  askPassword = true;

                  settings = {
                    # pass TRIM through to the SSD
                    allowDiscards = true;
                    # skip dm-crypt's read/write workqueues and submit I/O
                    # inline. the workqueues add queuing latency and cap IOPS.
                    bypassWorkqueues = true;
                  };

                  # match existing LUKS encryption parameters
                  extraFormatArgs = [
                    "--type"
                    "luks2"
                    "--cipher"
                    "aes-xts-plain64"
                    "--key-size"
                    "512"
                    "--pbkdf"
                    "argon2id"
                    "--pbkdf-memory"
                    "1048576"
                    "--pbkdf-parallel"
                    "4"
                    "--iter-time"
                    "2000"
                    # 4096 rather than the 512 used by the existing SATA
                    # containers. Matches the ext4 block size, so a block write is
                    # one crypto sector instead of eight, and avoids
                    # read-modify-write on sub-block updates.
                    "--sector-size"
                    "4096"
                  ];

                  content = {
                    type = "filesystem";
                    format = "ext4";
                    extraArgs = [
                      "-L"
                      "phlipdesk-root"
                      # 1% of ~474G ~= 4.7G reserved
                      "-m"
                      "1"
                      # fast commit to cut fsync latency
                      "-O"
                      "fast_commit"
                      # init inode table + journal at setup rather than lazily
                      "-E"
                      "lazy_itable_init=0,lazy_journal_init=0"
                    ];
                    mountpoint = "/";
                    mountOptions = [ "noatime" ];
                  };
                };
              };
            };
          };
        };
      };
    };

  };
}
