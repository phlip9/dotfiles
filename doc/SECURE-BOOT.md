# NixOS Secure Boot

Follow this guide to setup secure boot on a NixOS machine using the modern
[Limine] bootloader and [sbctl] Secure Boot key manager.


## How this works

Setting up secure boot effectively instructs the machine's BIOS to only boot
into bootloaders that are signed by a trusted key pair. To limit our attack
surface, we can even remove all vendor-default key pairs and replace them with
our own. This way, our machine will only boot into trusted system
configurations that we've explicitly signed with our own keys.

To get this going, we'll generate a new set of key pairs that only we control
(`/var/lib/sbctl/keys/{PK,KEK,db}`). These keys will form our Root-of-Trust.

Once we register these as our exclusive trusted pubkeys in our BIOS and enable
Secure Boot, the only system that our machine will load is one signed with our
keys.

Then, whenever we `nixos-rebuild switch` to a new system, a new
nixos-generation will get added to the Limine bootloader config
(`/boot/limine/limine.conf`). This config file contains content-hashed boot
entries:

```bash
$ sudo cat /boot/limine/limine.conf
timeout: 2
editor_enabled: no
hash_mismatch_panic: yes
graphics: yes
default_entry: 2
wallpaper: boot():/limine/wallpapers/nixos-nix-wallpaper-simple-dark-gray_bootloader.png#63e4fd14a1f49bdc99a7cf8460bd032d1f223b7447495aebf7db41662a94920ef815dce8e9011aa1c4363463b0319ec33c68d1187bd3428358853ad4df1df387
wallpaper_style: stretched
backdrop: 2F302F
interface_help_hidden: False

# NixOS boot entries start here
/+NixOS default profile
//Generation 80
protocol: linux
comment: NixOS Yarara 26.05pre916364.3e2499d5539c (Linux 6.18.2), built on 2025-12-28 17:28:28
kernel_path: boot():/limine/kernels/4yl7akp43x29szfc6lvlwd0ybfg2qkc7-linux-6.18.2-bzImage#0a26938b835bbc3c0507904437718acac71c09eee47efbcd6c3d6ac3d2d00c4c827f4b2255b3103c7dbd1a1e75c88c1ac52173704029848c3cbb083590f8935e
cmdline: init=/nix/store/5n8j4a9kbfiv5k6bgh6kw6ngrwrzw36r-nixos-system-phlipnixos-26.05pre916364.3e2499d5539c/init loglevel=4 lsm=landlock,yama,bpf nvidia-drm.modeset=1 nvidia-drm.fbdev=1
module_path: boot():/limine/kernels/swnrk6f0xjzc26nid3l4pfajr83gp8gc-initrd-linux-6.18.2-initrd#76f65179747161d4e9d7f7610e7032944bc8e71279a118ba9d6dbde51500c9b3d3ba50c1778e5c1c8ce837621c7c18d40b15eb40ad31773ce1858800cd7c9f71
//Generation 79
# ...
# NixOS boot entries end here
```

The switch process then commits the config file hash directly into the Limine
bootloader executable (`/boot/EFI/limine/BOOTX64.EFI`) using
`limine enroll-config /boot/EFI/limine/BOOTX64.EFI <config-hash>`.

Finally, it re-signs the updated bootloader with
`sbctl sign /boot/EFI/limine/BOOTX64.EFI`.

When we reboot next, our machine's BIOS will finally accept the bootloader, as
it's signed with our trusted key pair.


## Backup initial state

Before we get started, let's backup the existing enrolled keys in our BIOS:

```bash
$ nix-shell -p sbctl

$ sbctl status
Installed:      ✗ sbctl is not installed
Setup Mode:     ✓ Disabled
Secure Boot:    ✗ Disabled
Vendor Keys:    microsoft builtin-db builtin-db builtin-db builtin-db builtin-KEK builtin-KEK builtin-PK

$ sbctl list-enrolled-keys
PK:
  ASUSTeK MotherBoard PK Certificate
KEK:
  ASUSTeK MotherBoard KEK Certificate
  Microsoft Corporation Third Party Marketplace Root
  Canonical Ltd. Master Certificate Authority
  Microsoft RSA Devices Root CA 2021
DB:
  ASUSTeK MotherBoard SW Key Certificate
  ASUSTeK Notebook SW Key Certificate
  Microsoft Corporation Third Party Marketplace Root
  Microsoft Root Certificate Authority 2010
  Canonical Ltd. Master Certificate Authority
  Microsoft RSA Devices Root CA 2021
  Microsoft RSA Devices Root CA 2021

$ sbctl export-enrolled-keys --debug --disable-landlock --format=esl --dir ~/bak/sbctl-enrolled-keys
```


## Create keys and enroll

Reboot and enter the system BIOS menu.

- Under `Boot/Secure Boot/Key Management`, hit "Clear secure boot keys". This
  will remove all registered trusted pubkeys and reset the system into secure
  boot "Setup Mode" so that we can enroll our own keys using `sbctl`.

After booting back into NixOS:

```bash
# "Setup Mode" should now be enabled
$ sbctl status
Installed:      ✗ sbctl is not installed
Setup Mode:     ✗ Enabled
Secure Boot:    ✗ Disabled
Vendor Keys:    none

# Generate our new secure boot owner keys
$ sudo sbctl create-keys
Created Owner UUID a25cef84-1bfa-4793-be37-e72e23e4df27
Secure boot keys created!

$ ls -T /var/lib/sbctl
/var/lib/sbctl
├── GUID
└── keys
    ├── db
    │   ├── db.key
    │   └── db.pem
    ├── KEK
    │   ├── KEK.key
    │   └── KEK.pem
    └── PK
        ├── PK.key
        └── PK.pem

# Since my TPM2 doesn't appear to have an event log, verify that there are no
# important Option ROMs that need us to install the Microsoft CA:
$ fd ^rom$ /sys/devices --exec bash -c 'echo "{}: $(lspci -s "$(basename "$(dirname {})")")"'
/sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0/rom: 01:00.0 VGA compatible controller: NVIDIA Corporation GP102 [GeForce GTX 1080 Ti] (rev a1)

# Enroll our new keys.
#
# If you have important Option ROMs, you may need to trust the Microsoft CA
# (with --microsoft) or use the experimental --tpm-eventlog option.
$ sudo sbctl enroll-keys --yes-this-might-brick-my-machine
[sudo: authenticate] Password:
Enrolling keys to EFI variables... ✓
Enrolled keys to the EFI variables!
```


## Enable Secure Boot

Enable the Limine bootloader with secure boot in our NixOS config:

```nix
{
  boot.loader = {
    limine = {
      enable = true;
      efiSupport = true;
      secureBoot.enable = true;
    };
    efi.canTouchEfiVariables = true;
  };
}
```

```bash
# Switch to the new config. Signing should happen automatically.
$ nixos-rebuild switch
# ...
Config file BLAKE2B successfully enrolled.
signing limine...
✓ Signed /boot/efi/limine/BOOTX64.EFI
# ...

# limine should now be signed
$ sudo sbctl verify
Verifying file database and EFI images in /boot...
✗ /boot/EFI/BOOT/BOOTX64.EFI is not signed
✓ /boot/EFI/limine/BOOTX64.EFI is signed
✗ /boot/EFI/systemd/systemd-bootx64.efi is not signed
✗ /boot/limine/kernels/3p11vvfafdf3zs40wxwfs7zmj6liccg4-linux-6.17.9-bzImage is not signed
✗ /boot/limine/kernels/4yl7akp43x29szfc6lvlwd0ybfg2qkc7-linux-6.18.2-bzImage is not signed
# ...
```

Reboot again into the BIOS and fully enable Secure Boot:

- Change `Boot/Secure Boot/Boot/OS Type` from "Other" to "Windows UEFI".

- Disable any `Boot/Secure Boot/CSM (Compatibility Support Module)` option.

- Set a BIOS password, so an attacker can't just unset Secure Boot.

Once you're back in NixOS, `sbctl` should be happy:

```bash
$ sudo sbctl status
Installed:      ✓ sbctl is installed
Owner GUID:     a25cef84-1bfa-4793-be37-e72e23e4df27
Setup Mode:     ✓ Disabled
Secure Boot:    ✓ Enabled
Vendor Keys:    none
```

[Limine]: https://codeberg.org/Limine/Limine
[sbctl]: https://github.com/Foxboron/sbctl
