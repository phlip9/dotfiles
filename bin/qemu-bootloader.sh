#!/usr/bin/env bash
set -euxo pipefail

# Copy relevant parts of /boot partition to a tmpdir
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/boot/EFI/BOOT"
sudo cp -a /boot/EFI/limine/BOOTX64.EFI "$tmp/boot/EFI/BOOT/"
sudo cp -a /boot/limine "$tmp/boot"
sudo chown -R "$(id -u):$(id -g)" "$tmp/boot"

ovmf="$(nix build -f . --print-out-paths pkgsNixos.OVMF.fd | head -n1)/FV"

cp "$ovmf/OVMF_VARS.fd" "$tmp/"
chmod u+w "$tmp/OVMF_VARS.fd"

dua "$tmp"
eza -lT "$tmp"

qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -machine q35,accel=kvm \
    -m 1024 \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,file="$tmp/OVMF_VARS.fd" \
    -drive format=raw,if=virtio,file=fat:rw:"$tmp/boot" \
    -display gtk,gl=on \
    -boot menu=on \
    -name limine-boot-test,process=limine-boot-test \
    -net none
