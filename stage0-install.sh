#!/usr/bin/env bash
#
# GArchy Stage 0: Base system installer.
#
# Run either:
#   - from the Arch live ISO as root, or
#   - from a running Arch host with --from-host, targeting an attached disk
#     (e.g. an SSD in a USB enclosure) that will be moved to another machine.
#
# What it does:
# - Wipes the selected disk (UEFI + GPT)
# - Creates EFI + root partitions (swap via zram)
# - Installs base Arch with minimal packages (GRUB, greetd, NetworkManager, sshd)
# - Auto-detects CPU microcode (override with --ucode for cross-machine installs)
# - Creates a user (default: groot, member of wheel)
# - Clones GArchy into the new user's home
#
# Usage:
#   stage0-install.sh [--from-host] [--disk /dev/sdX] [--ucode amd|intel|both]
#                     [--hostname NAME] [--user NAME] [--surface]
#                     [--wifi CONNECTION_NAME]
#
# --wifi copies the named NetworkManager profile from this machine into the
# target so it auto-connects on first boot (headless SSH access over wifi).
#
# WARNING: This will DESTROY all data on the selected disk.

set -euo pipefail

# ----- options / globals -----
FROM_HOST=0
DISK=""
UCODE=""          # amd | intel | both | "" (auto-detect)
HOSTNAME=""
NEW_USER=""
IS_SURFACE="n"
WIFI_PROFILE=""   # NetworkManager connection name to copy into the target

log() {
  printf '\e[32m[GArchy/Stage0]\e[0m %s\n' "$*" >&2
}

err() {
  printf '\e[31m[GArchy/Stage0]\e[0m %s\n' "$*" >&2
}

usage() {
  sed -n "2,26p" "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-host)  FROM_HOST=1 ;;
      --disk)       DISK="${2:?--disk requires a value}"; shift ;;
      --ucode)      UCODE="${2:?--ucode requires amd|intel|both}"; shift ;;
      --hostname)   HOSTNAME="${2:?--hostname requires a value}"; shift ;;
      --user)       NEW_USER="${2:?--user requires a value}"; shift ;;
      --surface)    IS_SURFACE="y" ;;
      --wifi)       WIFI_PROFILE="${2:?--wifi requires a connection name}"; shift ;;
      -h|--help)    usage 0 ;;
      *)            err "Unknown option: $1"; usage 1 ;;
    esac
    shift
  done

  case "$UCODE" in
    ""|amd|intel|both) ;;
    *) err "--ucode must be amd, intel, or both (got: $UCODE)"; exit 1 ;;
  esac
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Must be run as root."
    exit 1
  fi
}

require_env() {
  if ((FROM_HOST)); then
    if [[ ! -f /etc/arch-release ]]; then
      err "--from-host requires a running Arch Linux host."
      exit 1
    fi
    if ! command -v pacstrap >/dev/null 2>&1; then
      log "Installing arch-install-scripts (provides pacstrap/genfstab/arch-chroot)..."
      pacman -S --needed --noconfirm arch-install-scripts
    fi
    # Partitioning/formatting tools the live ISO has but a host may not
    local missing=()
    command -v parted    >/dev/null 2>&1 || missing+=(parted)
    command -v mkfs.fat  >/dev/null 2>&1 || missing+=(dosfstools)
    command -v mkfs.ext4 >/dev/null 2>&1 || missing+=(e2fsprogs)
    if ((${#missing[@]} > 0)); then
      log "Installing missing tools: ${missing[*]}"
      pacman -S --needed --noconfirm "${missing[@]}"
    fi
    return 0
  fi

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
  if [[ -z "$DISK" ]]; then
    lsblk -dpno NAME,SIZE,TYPE,TRAN | grep 'disk'
    echo
    read -rp "Enter target disk to WIPE (e.g. /dev/nvme0n1): " DISK
  fi
  if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    err "Invalid disk: $DISK"
    exit 1
  fi

  # Safety: refuse to wipe a disk that hosts a mounted filesystem
  if lsblk -no MOUNTPOINTS "$DISK" | grep -q '\S'; then
    err "$DISK has mounted filesystems. Refusing to continue."
    lsblk "$DISK"
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
  if [[ -z "$HOSTNAME" ]]; then
    read -rp "Enter hostname [garchy]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-garchy}
  fi
}

ask_username() {
  if [[ -z "$NEW_USER" ]]; then
    read -rp "Enter username [groot]: " NEW_USER
    NEW_USER=${NEW_USER:-groot}
  fi
}

ask_surface() {
  if [[ "$IS_SURFACE" != "y" ]]; then
    read -rp "Is this a Microsoft Surface device? [y/N]: " IS_SURFACE
    IS_SURFACE=${IS_SURFACE:-n}
  fi
}

detect_ucode() {
  if [[ -z "$UCODE" ]]; then
    local vendor
    vendor=$(grep -m1 '^vendor_id' /proc/cpuinfo | awk '{print $3}')
    case "$vendor" in
      AuthenticAMD) UCODE="amd" ;;
      GenuineIntel) UCODE="intel" ;;
      *)            UCODE="both" ;;
    esac
    if ((FROM_HOST)); then
      log "NOTE: microcode auto-detected from THIS host's CPU ($UCODE)."
      log "      If the target machine differs, re-run with --ucode amd|intel|both."
    fi
  fi

  UCODE_PKGS=()
  case "$UCODE" in
    amd)   UCODE_PKGS=(amd-ucode) ;;
    intel) UCODE_PKGS=(intel-ucode) ;;
    both)  UCODE_PKGS=(amd-ucode intel-ucode) ;;
  esac
  log "Microcode: ${UCODE_PKGS[*]}"
}

partition_disk() {
  log "Partitioning $DISK (GPT, EFI + root)..."

  # Wipe filesystem/partition-table signatures (parted mklabel below
  # writes the fresh GPT, so no sgdisk/gptfdisk needed)
  wipefs -af "$DISK"

  # Create GPT: 1 - EFI (512M), 2 - root (rest)
  parted -s "$DISK" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart "root" ext4 513MiB 100%

  partprobe "$DISK"
  sleep 1

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
  if [[ "$IS_SURFACE" == "y" ]]; then
    log "Configuring linux-surface repository on install host..."
    curl -s https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
      | pacman-key --add -
    pacman-key --lsign-key 56C464BAAC421453

    if ! grep -q "\[linux-surface\]" /etc/pacman.conf; then
      cat <<EOT >> /etc/pacman.conf

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
EOT
    fi
    pacman -Sy
  fi

  log "Installing base system (this may take a while)..."

  local pkgs=(
    base
    linux
    linux-firmware
    "${UCODE_PKGS[@]}"
    grub
    efibootmgr
    zram-generator
    networkmanager
    openssh
    sudo
    git
    greetd
    hyprland
    uwsm
    reflector
    bash-completion
  )

  if [[ "$IS_SURFACE" == "y" ]]; then
    log "Adding linux-surface packages..."
    local new_pkgs=()
    for p in "${pkgs[@]}"; do
      [[ "$p" == "linux" ]] || new_pkgs+=("$p")
    done
    pkgs=("${new_pkgs[@]}" linux-surface linux-surface-headers iptsd)
  fi

  pacstrap /mnt "${pkgs[@]}"
}

generate_fstab() {
  log "Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab
}

configure_system_chroot() {
  log "Entering chroot to configure system..."

  arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

if [[ "$IS_SURFACE" == "y" ]]; then
  echo "Configuring linux-surface repository in target..."
  curl -s https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
    | pacman-key --add -
  pacman-key --lsign-key 56C464BAAC421453

  if ! grep -q "\[linux-surface\]" /etc/pacman.conf; then
    cat <<EOT >> /etc/pacman.conf

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
EOT
  fi
  pacman -Sy --noconfirm
fi

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

# Swap via zram (no swapfile/partition)
mkdir -p /etc/systemd
cat <<EOT >/etc/systemd/zram-generator.conf
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
EOT

# Enable NetworkManager, sshd, greetd
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable greetd

if [[ "$IS_SURFACE" == "y" ]]; then
  systemctl enable iptsd
fi

# Install bootloader (GRUB, UEFI).
# --removable installs to the fallback path (EFI/BOOT/BOOTX64.EFI) so the
# disk boots on any machine without needing host NVRAM entries -- required
# when installing from another machine (--from-host) and moving the disk.
grub-install --target=x86_64-efi --efi-directory=/boot \
  --bootloader-id=GArchy --removable --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Create user and enable sudo
if ! id "$NEW_USER" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$NEW_USER"
  echo "Setting default password 'archlinux' for user $NEW_USER"
  echo "$NEW_USER:archlinux" | chpasswd
  passwd -e "$NEW_USER"  # Force password change on first login
fi

if ! grep -qE '^%wheel\\s+ALL=\\(ALL:ALL\\)\\s+ALL' /etc/sudoers; then
  echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

EOF
}

copy_wifi_profile() {
  [[ -n "$WIFI_PROFILE" ]] || return 0

  local src="/etc/NetworkManager/system-connections/${WIFI_PROFILE}.nmconnection"
  if [[ ! -f "$src" ]]; then
    err "WiFi profile not found: $src"
    err "Available profiles:"
    ls /etc/NetworkManager/system-connections/ 2>/dev/null | sed 's/\.nmconnection$//; s/^/  - /' >&2
    err "Continuing without WiFi profile."
    return 0
  fi

  log "Copying WiFi profile '$WIFI_PROFILE' into target..."
  local dst_dir="/mnt/etc/NetworkManager/system-connections"
  mkdir -p "$dst_dir"
  cp "$src" "$dst_dir/"
  # Strip interface pinning so the profile matches the target's wifi device
  sed -i '/^interface-name=/d' "$dst_dir/${WIFI_PROFILE}.nmconnection"
  chmod 600 "$dst_dir/${WIFI_PROFILE}.nmconnection"
  log "Target will auto-connect to '$WIFI_PROFILE' on boot."
}

clone_garchy_into_new_system() {
  log "Cloning GArchy into /mnt/home/$NEW_USER/GArchy..."
  # Clone as root then chown: 'su - user' would fail because the user's
  # password is expired (forced change on first login).
  arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail
if [[ ! -d "/home/$NEW_USER/GArchy/.git" ]]; then
  git clone https://github.com/madmax3553/GArchy "/home/$NEW_USER/GArchy"
  chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/GArchy"
fi
EOF
}

main() {
  parse_args "$@"
  require_root
  require_env

  select_disk
  ask_hostname
  ask_username
  ask_surface
  detect_ucode

  partition_disk
  format_partitions
  mount_partitions
  install_base_system
  generate_fstab
  configure_system_chroot
  copy_wifi_profile
  clone_garchy_into_new_system

  umount -R /mnt || true

  log "Stage0 complete."
  if ((FROM_HOST)); then
    log "You can now detach $DISK and boot it in the target machine."
    log "It will come up with DHCP + sshd. Then:"
    log "  ssh $NEW_USER@<target-ip>   (password: archlinux, change forced)"
  else
    log "You can now reboot into the new system, then log in as $NEW_USER."
  fi
  log "Finally run:"
  log "  cd ~/GArchy && ./stage1-setup.sh"
}

main "$@"
