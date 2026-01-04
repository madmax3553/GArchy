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

To install GArchy on this machine, run:

  /usr/local/share/GArchy/stage0-install.sh

EOF
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
