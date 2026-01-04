#!/usr/bin/env bash
#
# GArchy Stage 0: Run from Arch ISO as root.
# - Wipes a selected disk (UEFI + GPT)
# - Creates EFI + root partitions (swap via swapfile on root)
# - Installs base Arch with minimal packages
# - Creates a user (default: groot, member of wheel)
# - Enables sshd, NetworkManager, sddm
# - Clones GArchy into the new user's home
#
# WARNING: This will DESTROY all data on the selected disk.

set -euo pipefail

log() {
  printf '\e[32m[GArchy/Stage0]\e[0m %s\n' "$*" >&2
}

err() {
  printf '\e[31m[GArchy/Stage0]\e[0m %s\n' "$*" >&2
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Must be run as root."
    exit 1
  fi
}

require_arch_iso() {
  if [[ ! -f /run/archiso/bootmnt/arch/aitab ]]; then
    err "This looks like it's not an Arch ISO environment. Continue anyway? [y/N]"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
  fi
}

confirm() {
  local prompt="${1:-Are you sure?}"
  read -rp "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

select_disk() {
  lsblk -dpno NAME,SIZE,TYPE | grep 'disk'
  echo
  read -rp "Enter target disk to WIPE (e.g. /dev/nvme0n1): " DISK
  if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    err "Invalid disk: $DISK"
    exit 1
  fi

  echo
  lsblk -dpno NAME,SIZE,TYPE "$DISK"
  echo
  if ! confirm "THIS WILL WIPE $DISK COMPLETELY. Continue?"; then
    err "Aborting."
    exit 1
  fi
}

ask_hostname() {
  read -rp "Enter hostname [garchy]: " HOSTNAME
  HOSTNAME=${HOSTNAME:-garchy}
}

ask_username() {
  read -rp "Enter username [groot]: " NEW_USER
  NEW_USER=${NEW_USER:-groot}
}

partition_disk() {
  log "Partitioning $DISK (GPT, EFI + root)..."

  # Wipe partition table
  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"

  # Create GPT: 1 - EFI (512M), 2 - root (rest)
  parted -s "$DISK" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart "root" ext4 513MiB 100%

  partprobe "$DISK"

  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
  [[ -b "$EFI_PART" && -b "$ROOT_PART" ]] || {
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
  }

  log "EFI:  $EFI_PART"
  log "Root: $ROOT_PART"
}

format_partitions() {
  log "Formatting EFI partition as FAT32..."
  mkfs.fat -F32 "$EFI_PART"

  log "Formatting root partition as ext4..."
  mkfs.ext4 -F "$ROOT_PART"
}

mount_partitions() {
  log "Mounting root partition..."
  mount "$ROOT_PART" /mnt

  log "Creating /mnt/boot and mounting EFI..."
  mkdir -p /mnt/boot
  mount "$EFI_PART" /mnt/boot
}

install_base_system() {
  log "Installing base system (this may take a while)..."

  pacstrap /mnt \
    base \
    linux \
    linux-firmware \
    networkmanager \
    openssh \
    sudo \
    git \
    sddm \
    hyprland \
    reflector \
    bash-completion
}

generate_fstab() {
  log "Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab
}

configure_system_chroot() {
  log "Entering chroot to configure system..."

  arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "$HOSTNAME" > /etc/hostname

cat <<EOT >/etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOT

# Timezone & clock (adjust as you like)
ln -sf /usr/share/zoneinfo/Canada/Eastern /etc/localtime || true
hwclock --systohc || true

# Locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Enable NetworkManager, sshd, sddm
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable sddm

# Install bootloader (systemd-boot, UEFI only)
bootctl --path=/boot install

# Basic systemd-boot entry
ROOT_UUID=\$(blkid -s UUID -o value "$ROOT_PART")
cat <<BOOT >/boot/loader/entries/arch.conf
title   Arch Linux (GArchy)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=\$ROOT_UUID rw
BOOT

cat <<LOADER >/boot/loader/loader.conf
default arch.conf
timeout 3
editor  no
LOADER

# Create user and enable sudo
if ! id "$NEW_USER" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$NEW_USER"
  echo "Set password for user $NEW_USER:"
  passwd "$NEW_USER"
fi

pacman -S --needed --noconfirm sudo

if ! grep -qE '^%wheel\\s+ALL=\\(ALL:ALL\\)\\s+ALL' /etc/sudoers; then
  echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

EOF
}

clone_garchy_into_new_system() {
  log "Cloning GArchy into /mnt/home/$NEW_USER/GArchy..."
  arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail
su - "$NEW_USER" -c 'git clone https://github.com/madmax3553/GArchy "\$HOME/GArchy" || true'
EOF
}

main() {
  require_root
  require_arch_iso

  select_disk
  ask_hostname
  ask_username

  partition_disk
  format_partitions
  mount_partitions
  install_base_system
  generate_fstab
  configure_system_chroot
  clone_garchy_into_new_system

  log "Stage0 complete. You can now reboot into the new system."
  log "After reboot, log in as $NEW_USER and run:"
  log "  cd ~/GArchy"
  log "  ./stage1-setup.sh"
}

main "$@"