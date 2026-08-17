#!/usr/bin/env bash
#
# Build a custom GArchy Arch ISO using archiso.
# Run this on an existing Arch system (not in the live ISO).

set -euo pipefail

PROFILE_NAME="garchy"
WORKDIR="${WORKDIR:-$PWD/archiso-work}"
OUTDIR="${OUTDIR:-$PWD/out}"

log() {
  printf '\e[32m[GArchy/ISO]\e[0m %s\n' "$*" >&2
}

err() {
  printf '\e[31m[GArchy/ISO]\e[0m %s\n' "$*" >&2
}

require_archiso() {
  if ! command -v mkarchiso >/dev/null 2>&1; then
    err "mkarchiso not found. Install archiso first:"
    err "  sudo pacman -Syu --needed archiso"
    exit 1
  fi
}

prepare_profile() {
  log "Preparing archiso profile for $PROFILE_NAME..."

  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"

  cp -r /usr/share/archiso/configs/releng "$WORKDIR/$PROFILE_NAME"

  local profdir="$WORKDIR/$PROFILE_NAME"

  mkdir -p "$profdir/airootfs/usr/local/share"
  rsync -a --exclude '.git' "$PWD"/ "$profdir/airootfs/usr/local/share/GArchy/"

  cat >"$profdir/airootfs/root/GARCHY-INSTALL.txt" <<'EOF'
Welcome to the GArchy Arch ISO.

This live environment starts sshd automatically (DHCP). To install
headlessly, find this machine's IP and connect from another box:

  ssh root@<ip>       # key-based if a key was baked in at build time,
                      # or use GARCHY_LIVE_ROOT_PW set during build

To install GArchy on this machine, run:

  /usr/local/share/GArchy/stage0-install.sh

If this ISO was written directly to the target disk, it booted with
copytoram=y, so the disk is free to be wiped by stage0.

EOF

  # --- Headless: enable sshd in the live environment ---
  log "Enabling sshd in live environment..."
  mkdir -p "$profdir/airootfs/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/sshd.service \
    "$profdir/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service"

  # Bake in SSH public keys for root, if available
  local pubkeys
  pubkeys=$(cat ~/.ssh/*.pub 2>/dev/null || true)
  if [[ -n "$pubkeys" ]]; then
    log "Adding $(wc -l <<<"$pubkeys") SSH public key(s) to live root authorized_keys..."
    mkdir -p "$profdir/airootfs/root/.ssh"
    printf '%s\n' "$pubkeys" > "$profdir/airootfs/root/.ssh/authorized_keys"
    chmod 700 "$profdir/airootfs/root/.ssh"
    chmod 600 "$profdir/airootfs/root/.ssh/authorized_keys"
    # Register permissions with archiso so they survive image build
    sed -i '/^file_permissions=(/a\  ["/root/.ssh"]="0:0:700"\n  ["/root/.ssh/authorized_keys"]="0:0:600"' \
      "$profdir/profiledef.sh"
  else
    log "No ~/.ssh/*.pub found; no keys baked in."
  fi

  # Optional live root password (default: none => key-only SSH login)
  if [[ -n "${GARCHY_LIVE_ROOT_PW:-}" ]]; then
    log "Setting live root password from GARCHY_LIVE_ROOT_PW..."
    local hash
    hash=$(openssl passwd -6 "$GARCHY_LIVE_ROOT_PW")
    mkdir -p "$profdir/airootfs/etc"
    if [[ -f "$profdir/airootfs/etc/shadow" ]]; then
      sed -i "s|^root:[^:]*:|root:${hash//|/\\|}:|" "$profdir/airootfs/etc/shadow"
    else
      printf 'root:%s:14871::::::\n' "$hash" > "$profdir/airootfs/etc/shadow"
      chmod 400 "$profdir/airootfs/etc/shadow"
    fi
    # Allow password auth for root over SSH in the live env
    mkdir -p "$profdir/airootfs/etc/ssh/sshd_config.d"
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' \
      > "$profdir/airootfs/etc/ssh/sshd_config.d/10-garchy-live.conf"
  fi

  # --- copytoram=y: run entirely from RAM so the boot disk can be wiped ---
  # Lets you dd this ISO straight onto the target SSD and install over it.
  log "Baking copytoram=y into boot entries..."
  local f
  for f in "$profdir"/efiboot/loader/entries/*.conf; do
    [[ -e "$f" ]] || continue
    sed -i '/^options / s/$/ copytoram=y/' "$f"
  done
  for f in "$profdir"/syslinux/*.cfg; do
    [[ -e "$f" ]] || continue
    sed -i '/^\s*APPEND / s/$/ copytoram=y/' "$f"
  done
  if [[ -f "$profdir/grub/grub.cfg" ]]; then
    sed -i '/archisobasedir=/ s/archisobasedir=/copytoram=y archisobasedir=/' \
      "$profdir/grub/grub.cfg"
  fi
}

build_iso() {
  local profdir="$WORKDIR/$PROFILE_NAME"
  mkdir -p "$OUTDIR"

  log "Building ISO (this may take a while)..."
  mkarchiso -v -w "$profdir/work" -o "$OUTDIR" "$profdir"

  log "ISO build finished. Files in: $OUTDIR"
  ls -1 "$OUTDIR"
}

main() {
  require_archiso
  prepare_profile
  build_iso
}

main "$@"
