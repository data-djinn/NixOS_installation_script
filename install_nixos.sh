#!/usr/bin/env bash
# Btrfs erase-your-darlings NixOS installer
# CAUTION: THIS SCRIPT WILL NUKE YOUR HARD DRIVE. DO NOT USE IF YOU WISH TO RETAIN DATA
# Initially forked from:
# CC0 - Konrad Förstner <konrad@foerstner>
# https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt
#
# Inspired by: https://mt-caret.github.io/blog/posts/2020-06-29-optin-state.html
# Public-domain.

set -euo pipefail

###############################################################################
# YOU PROBABLY ONLY NEED TO CHANGE THESE THREE LINES
###############################################################################
DISK=/dev/nvme0n1              # target disk (hard drives will be like "dev/sda")
HOSTNAME="nixos-btrfs"         # hostname to write into configuration.nix
USERNAME="sean"                # your first user

###############################################################################
# STATIC CONSTANTS – LEAVE ALONE UNLESS YOU KNOW WHAT YOU’RE DOING
###############################################################################
BOOT_PART=${DISK}p1
CRYPT_PART=${DISK}p2
CRYPT_NAME=cryptroot
TMP_CFG=/mnt/etc/nixos/configuration.nix

###############################################################################
print_help() {
  echo "Usage: $0 <stage>"
  echo "Stages:"
  echo "  partitions   – wipe disk and create EFI + LUKS partitions"
  echo "  luks         – initialise LUKS and open it as /dev/mapper/${CRYPT_NAME}"
  echo "  format       – create Btrfs fs and subvolumes"
  echo "  mount        – mount subvolumes and generate Nix config"
  echo "  patch_cfg    – rewrite config for erase-your-darlings"
  echo "  install      – nixos-install && reboot"
  echo "  all          – run EVERYTHING (danger: will nuke ${DISK})"
}

###############################################################################
partitions() {
  echo ">>> Partitioning ${DISK}"
  wipefs -af "${DISK}"
  sgdisk -Zo "${DISK}"
  # EFI (1 GiB)
  sgdisk -n 1:0:+1G   -t 1:EF00 "${DISK}"
  # LUKS container – rest of the disk
  sgdisk -n 2:0:0     -t 2:8300 "${DISK}"
}

luks() {
  echo ">>> Setting up LUKS on ${CRYPT_PART}"
  cryptsetup luksFormat --type luks2 "${CRYPT_PART}"
  cryptsetup open "${CRYPT_PART}" "${CRYPT_NAME}"
}

format() {
  echo ">>> Formatting Btrfs and creating subvolumes"
  mkfs.vfat -n EFI "${BOOT_PART}"
  mkfs.btrfs -L nixos /dev/mapper/${CRYPT_NAME}

  # Mount once to create subvolumes, then unmount.
  mount /dev/mapper/${CRYPT_NAME} /mnt
  btrfs subvolume create /mnt/@root
  btrfs subvolume create /mnt/@nix
  btrfs subvolume create /mnt/@persist
  btrfs subvolume create /mnt/@log
  umount /mnt
}

mount() {
  echo ">>> Mounting subvolumes"
  mount -o subvol=@root,compress=zstd,noatime /dev/mapper/${CRYPT_NAME} /mnt
  mkdir -p /mnt/{boot,nix,persist,var/log}
  mount -o subvol=@nix,compress=zstd,noatime  /dev/mapper/${CRYPT_NAME} /mnt/nix
  mount -o subvol=@persist,compress=zstd,noatime /dev/mapper/${CRYPT_NAME} /mnt/persist
  mount -o subvol=@log,compress=zstd,noatime /dev/mapper/${CRYPT_NAME} /mnt/var/log
  mount "${BOOT_PART}" /mnt/boot

  nixos-generate-config --root /mnt
}

patch_cfg() {
  echo ">>> Patching ${TMP_CFG} for erase-your-darlings"

  # Strip the trailing } in auto-generated config - we'll add it back later
  sed -i '$ d' "${TMP_CFG}"

cat >> "${TMP_CFG}" <<'NIX'
###############################################################################
#  Btrfs-erase-your-darlings boilerplate – auto-generated
###############################################################################

# ZRAM swap instead of a swap partition
services.zramSwap = {
  enable = true;
  algorithm = zstd;
  memoryPercent = 25; # lower if you've got lots of RAM
  priority = 100;
};

fileSystems."/" = {
  device = "/dev/mapper/cryptroot";
  options = [ "subvol=@root" "compress=zstd" "noatime" ];
  fsType = "btrfs";
};

fileSystems."/nix" = {
  device = "/dev/mapper/cryptroot";
  options = [ "subvol=@nix" "compress=zstd" "noatime" ];
  fsType = "btrfs";
};

fileSystems."/persist" = {
  device = "/dev/mapper/cryptroot";
  options = [ "subvol=@persist" "compress=zstd" "noatime" ];
  fsType = "btrfs";
  neededForBoot = true;
};

fileSystems."/var/log" = {
  device = "/dev/mapper/cryptroot";
  options = [ "subvol=@log" "compress=zstd" "noatime" ];
  fsType = "btrfs";
};

# Make critical paths persistent by bind-mounting them into /persist
environment.etc."/nixos".source = "/persist/etc/nixos";
environment.persistence."/persist" = {
  directories = [
    "/var/lib/bluetooth"
    "/var/lib/systemd/coredump"
    "/var/lib/NetworkManager"     # wifi credentials
    "/home"
  ];
  files = [
    "/etc/machine-id"
  ];
};

boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-partlabel/cryptroot";

networking.hostName = "${HOSTNAME}";
networking.networkmanager.enable = true;

users.users.${USERNAME} = {
  isNormalUser = true;
  extraGroups = [ "wheel" "networkmanager" ];
};

nix.settings.experimental-features = [ "nix-command" "flakes" ];

###############################################################################
NIX

  echo "}" >> "${TMP_CFG}"
}

install() {
  echo ">>> Installing NixOS (grab coffee…)"
  nixos-install --no-root-passwd
  echo ">>> Done. Rebooting in 5 s."
  sleep 5
  reboot
}

###############################################################################
all() { partitions; luks; format; mount; patch_cfg; install; }

###############################################################################
# Entry-point
###############################################################################
if [[ $# -eq 0 ]]; then
  print_help
  exit 1
fi

for stage in "$@"; do
  "$stage"
done
