#!/usr/bin/env bash
#
# GArchy Stage 1: Desktop & dotfiles setup for user (default 'groot')
# - Refreshes mirrorlist with reflector (Canada, HTTPS)
# - Installs repo packages (mandatory, default*, optional*)
# - Installs AUR packages (mandatory, default*, optional*) via yay-bin
# - Clones madmax3553/dotfiles and applies them via stow, gated by installed tools

set -euo pipefail

GARCHY_ROOT="${GARCHY_ROOT:-$HOME/GArchy}"
PKG_DIR="$GARCHY_ROOT/packages"
DOTFILES_DIR="$HOME/dotfiles"
AUR_HELPER="yay"   # yay-bin from AUR

log() {
  printf '\e[32m[GArchy/Stage1]\e[0m %s\n' "$*" >&2
}

err() {
  printf '\e[31m[GArchy/Stage1]\e[0m %s\n' "$*" >&2
}

confirm() {
  local prompt="${1:-Are you sure?}"
  read -rp "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

require_user_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    err "Do not run this as root. Run as your normal user (default: groot)."
    exit 1
  fi
}

require_arch() {
  if [[ ! -f /etc/arch-release ]]; then
    err "This script is intended for Arch Linux."
    exit 1
  fi
}

read_pkg_list() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    err "Package list file not found: $file"
    return 1
  fi
  grep -vE '^\s*($|#)' "$file" || true
}

show_pkg_list() {
  local label="$1" file="$2"
  echo
  echo "=== $label packages from $file ==="
  if ! read_pkg_list "$file" | sed 's/^/  - /'; then
    echo "  (none)"
  fi
  echo
}

install_repo_pkgs() {
  local label="$1"; shift
  local pkgs=("$@")
  if ((${#pkgs[@]} == 0)); then
    log "No $label packages to install."
    return 0
  fi
  log "Installing $label packages via pacman: ${pkgs[*]}"
  sudo pacman -S --needed --noconfirm "${pkgs[@]}"
}

install_pkg_list_pacman_only() {
  local label="$1" file="$2"
  mapfile -t pkgs < <(read_pkg_list "$file")
  if ((${#pkgs[@]} == 0)); then
    log "No packages in $label list ($file), skipping."
    return 0
  fi
  install_repo_pkgs "$label" "${pkgs[@]}"
}

run_reflector_once() {
  if ! command -v reflector >/dev/null 2>&1; then
    log "Installing reflector first to refresh mirrorlist..."
    sudo pacman -Syu --needed --noconfirm reflector
  fi

  log "Refreshing pacman mirrorlist with reflector (Canada, HTTPS)..."
  sudo reflector \
    --country 'Canada' \
    --latest 20 \
    --protocol https \
    --sort rate \
    --save /etc/pacman.d/mirrorlist

  log "Mirrorlist updated. Proceeding with package installation..."
}

install_mandatory() {
  local file="$PKG_DIR/mandatory.txt"
  show_pkg_list "Mandatory" "$file"
  log "Installing mandatory package set (no prompt)..."
  install_pkg_list_pacman_only "Mandatory" "$file"
}

install_default_with_prompt() {
  local file="$PKG_DIR/default.txt"
  if [[ ! -f "$file" ]]; then
    log "No default package list ($file), skipping."
    return 0
  fi
  show_pkg_list "Default" "$file"
  if confirm "Install default package set?"; then
    install_pkg_list_pacman_only "Default" "$file"
  else
    log "Skipping default package set."
  fi
}

install_optional_sets() {
  local opt_dir="$PKG_DIR/optional"
  if [[ ! -d "$opt_dir" ]]; then
    log "No optional package directory ($opt_dir), skipping."
    return 0
  fi

  for file in "$opt_dir"/*.txt; do
    [[ -e "$file" ]] || continue
    local group_name
    group_name=$(basename "$file" .txt)
    show_pkg_list "Optional: $group_name" "$file"
    if confirm "Install optional set '$group_name'?"; then
      install_pkg_list_pacman_only "Optional:$group_name" "$file"
    else
      log "Skipping optional set '$group_name'."
    fi
  done
}

setup_yay_if_needed() {
  if command -v "$AUR_HELPER" >/dev/null 2>&1; then
    log "AUR helper '$AUR_HELPER' already installed."
    return 0
  fi

  log "Installing AUR helper '$AUR_HELPER' (requires base-devel and git)..."
  sudo pacman -S --needed --noconfirm base-devel git

  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  git clone https://aur.archlinux.org/yay-bin.git
  cd yay-bin
  makepkg -si --noconfirm
  popd >/dev/null
  rm -rf "$tmpdir"

  log "AUR helper '$AUR_HELPER' installed."
}

install_aur_list() {
  local label="$1" file="$2"
  mapfile -t pkgs < <(read_pkg_list "$file")
  if ((${#pkgs[@]} == 0)); then
    log "No AUR packages in $label list ($file), skipping."
    return 0
  fi
  if ! command -v "$AUR_HELPER" >/dev/null 2>&1; then
    err "AUR helper '$AUR_HELPER' not installed; cannot install $label list."
    return 1
  fi
  log "Installing $label AUR packages via $AUR_HELPER..."
  "$AUR_HELPER" -S --needed --noconfirm "${pkgs[@]}"
}

install_aur_sets() {
  setup_yay_if_needed

  local aur_m="$PKG_DIR/aur-mandatory.txt"
  local aur_d="$PKG_DIR/aur-default.txt"
  local aur_o="$PKG_DIR/aur-optional.txt"

  if [[ -f "$aur_m" ]]; then
    show_pkg_list "AUR Mandatory" "$aur_m"
    install_aur_list "AUR Mandatory" "$aur_m"
  fi

  if [[ -f "$aur_d" ]]; then
    show_pkg_list "AUR Default" "$aur_d"
    if confirm "Install AUR default set?"; then
      install_aur_list "AUR Default" "$aur_d"
    else
      log "Skipping AUR default set."
    fi
  fi

  if [[ -f "$aur_o" ]]; then
    show_pkg_list "AUR Optional" "$aur_o"
    if confirm "Install AUR optional set?"; then
      install_aur_list "AUR Optional" "$aur_o"
    else
      log "Skipping AUR optional set."
    fi
  fi
}

clone_dotfiles() {
  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    log "Dotfiles repo already present at $DOTFILES_DIR, pulling latest..."
    git -C "$DOTFILES_DIR" pull --ff-only
  else
    log "Cloning dotfiles into $DOTFILES_DIR..."
    git clone https://github.com/madmax3553/dotfiles "$DOTFILES_DIR"
  fi
}

apply_dotfiles_stow() {
  if ! command -v stow >/dev/null 2>&1; then
    err "stow not installed; cannot apply dotfiles."
    return 1
  fi

  log "Applying dotfiles with stow (only for installed tools)..."
  cd "$DOTFILES_DIR"

  declare -A STOW_REQUIRE_CMDS=(
    [bash]=""           # always stow shell config
    [bin]=""            # always stow scripts
    [nvim]="nvim"
    [hypr]="Hyprland"
    [rofi]="rofi tofi"
    [yazi]="yazi"
    [ranger]="ranger"
    [qtile]="qtile"
  )

  for pkg in "${!STOW_REQUIRE_CMDS[@]}"; do
    local pkg_dir="$DOTFILES_DIR/$pkg"

    if [[ ! -d "$pkg_dir" ]]; then
      log "Skipping $pkg (directory not found in dotfiles)."
      continue
    fi

    local req="${STOW_REQUIRE_CMDS[$pkg]}"
    local missing=0

    if [[ -n "$req" ]]; then
      for cmd in $req; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
          missing=1
          break
        fi
      done
    fi

    if (( missing )); then
      log "Skipping $pkg (required command(s) not found: $req)."
      continue
    fi

    log "Stowing $pkg..."
    stow -R "$pkg"
  done
}

main() {
  require_user_not_root
  require_arch

  if [[ ! -d "$PKG_DIR" ]]; then
    err "Package directory not found: $PKG_DIR"
    exit 1
  fi

  log "Starting GArchy Stage 1 setup for user '$(id -un)'..."

  if ! command -v sudo >/dev/null 2>&1; then
    err "'sudo' is not installed; install it from root first."
    exit 1
  fi
  if ! command -v pacman >/dev/null 2>&1; then
    err "pacman not found; this is not a standard Arch install."
    exit 1
  fi

  run_reflector_once

  install_mandatory
  install_default_with_prompt
  install_optional_sets

  install_aur_sets

  clone_dotfiles
  apply_dotfiles_stow

  log "GArchy Stage 1 complete. Log out and start an SDDM/Hyprland session."
}

main "$@"
