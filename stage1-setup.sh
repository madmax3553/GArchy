#!/usr/bin/env bash
#
# GArchy Stage 1: Desktop & dotfiles setup for user (default 'groot')
# - Refreshes mirrorlist with reflector (Canada, HTTPS)
# - Interactively asks user what to install (mandatory, default, optional)
# - Installs repo packages (mandatory, default*, optional*)
# - Installs AUR packages (mandatory, default*, optional*) via yay-bin
# - Asks if user wants dotfiles or vanilla configs
# - If dotfiles: clones madmax3553/dotfiles and stows only installed packages

set -euo pipefail

GARCHY_ROOT="${GARCHY_ROOT:-$HOME/GArchy}"
PKG_DIR="$GARCHY_ROOT/packages"
DOTFILES_DIR="$HOME/dotfiles"
AUR_HELPER="yay"   # yay-bin from AUR
INSTALLED_PKGS=()  # Track what we installed for stow decisions

log() {
  printf '\e[32m[GArchy/Stage1]\e[0m %s\n' "$*" >&2
}

err() {
  printf '\e[31m[GArchy/Stage1]\e[0m %s\n' "$*" >&2
}

confirm() {
  local prompt="${1:-Are you sure?}"
  local ans
  read -rp "$prompt [y/N]: " ans < /dev/tty
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
  echo "========================================"
  echo "=== $label packages ==="
  echo "========================================"
  if ! read_pkg_list "$file" | sed 's/^/  - /'; then
    echo "  (none)"
  fi
  echo "========================================"
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
  
  # Install packages, capturing output to check for failures
  local install_output
  install_output=$(sudo pacman -S --needed --noconfirm "${pkgs[@]}" 2>&1) || true
  echo "$install_output"
  
  # Check for failed packages
  local failed_pkgs=()
  while IFS= read -r line; do
    if [[ "$line" =~ "error: target not found: "(.+) ]]; then
      failed_pkgs+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ "could not find all required packages: "(.+) ]]; then
      # Handle dependency errors - extract package name
      local missing="${BASH_REMATCH[1]}"
      failed_pkgs+=("$missing")
    fi
  done <<< "$install_output"
  
  if ((${#failed_pkgs[@]} > 0)); then
    err "Warning: Could not install some packages: ${failed_pkgs[*]}"
    log "Continuing with remaining packages..."
  fi
  
  # Track successfully installed packages (exclude failed ones)
  for pkg in "${pkgs[@]}"; do
    local is_failed=0
    for failed in "${failed_pkgs[@]}"; do
      [[ "$pkg" == "$failed" ]] && is_failed=1 && break
    done
    ((is_failed)) || INSTALLED_PKGS+=("$pkg")
  done
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
  log "These packages are REQUIRED and will be installed automatically."
  read -n 1 -s -r -p "Press any key to continue..." < /dev/tty
  echo
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
  # Track installed packages
  INSTALLED_PKGS+=("${pkgs[@]}")
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

  log "Determining which dotfiles to stow based on installed packages..."
  cd "$DOTFILES_DIR"

  # Map dotfile directories to package names or commands
  # Format: [dotfile_dir]="package_name_or_command"
  declare -A DOTFILE_PKG_MAP=(
    [bash]="bash"
    [fish]="fish"
    [bin]="ALWAYS"
    [shell]="ALWAYS"
    [git]="git"
    [nvim]="neovim"
    [vim]="vim"
    [kitty]="kitty"
    [ghostty]="ghostty"
    [tmux]="tmux"
    [hypr]="hyprland"
    [qtile]="qtile"
    [sway]="sway"
    [rofi]="rofi"
    [tofi]="tofi"
    [waybar]="waybar"
    [dunst]="dunst"
    [swaync]="swaync"
    [yazi]="yazi"
    [ranger]="ranger"
    [vifm]="vifm"
    [mc]="mc"
    [btop]="btop"
    [htop]="htop"
    [bashtop]="bashtop"
    [neofetch]="neofetch"
    [starship.toml]="starship"
    [qutebrowser]="qutebrowser"
    [mpv]="mpv"
    [mpd]="mpd"
    [cava]="cava"
    [lazygit]="lazygit"
    [newsboat]="newsboat"
    [glow]="glow"
    [wlogout]="wlogout"
    [waypaper]="waypaper"
    [kdeconnect]="kdeconnect"
    [wallust]="wallust"
    [wal]="python-pywal"
    [termusic]="termusic"
    [calcure]="calcure"
    [qalculate]="qalculate-gtk"
    [sc-im]="sc-im"
    [yay]="yay"
    [copilot]="github-copilot-cli"
    [github-copilot]="github-copilot-cli"
    [cargo]="cargo"
    [go]="go"
    [gtk-3.0]="gtk3"
    [gtk-4.0]="gtk4"
    [qt5ct]="qt5ct"
    [qt6ct]="qt6ct"
    [pulse]="pulseaudio"
    [pavucontrol.ini]="pavucontrol"
    [systemd]="systemd"
    [ssh]="openssh"
    [x11]="xorg-server"
  )

  # Convert installed packages to lowercase for comparison
  declare -A installed_lookup
  for pkg in "${INSTALLED_PKGS[@]}"; do
    installed_lookup["${pkg,,}"]=1
  done

  # Stow directories where package is installed or command exists
  for dotfile_dir in "$DOTFILES_DIR"/*/; do
    [[ -d "$dotfile_dir" ]] || continue
    local dir_name
    dir_name=$(basename "$dotfile_dir")
    
    # Skip hidden dirs
    [[ "$dir_name" =~ ^\. ]] && continue

    local pkg_name="${DOTFILE_PKG_MAP[$dir_name]:-}"
    
    # If not in map, skip conservatively
    if [[ -z "$pkg_name" ]]; then
      log "Skipping $dir_name (not in dotfile map)."
      continue
    fi

    # Always stow certain directories
    if [[ "$pkg_name" == "ALWAYS" ]]; then
      log "Stowing $dir_name (always)..."
      stow -R "$dir_name" 2>/dev/null || log "Warning: stow failed for $dir_name"
      continue
    fi

    # Check if package was installed or command exists
    local pkg_lower="${pkg_name,,}"
    if [[ -v installed_lookup["$pkg_lower"] ]] || command -v "$pkg_name" >/dev/null 2>&1; then
      log "Stowing $dir_name (found: $pkg_name)..."
      stow -R "$dir_name" 2>/dev/null || log "Warning: stow failed for $dir_name"
    else
      log "Skipping $dir_name (package '$pkg_name' not installed)."
    fi
  done
}

configure_services() {
  log "Setting up system services and configuration..."
  
  # Enable display manager if installed
  if command -v sddm >/dev/null 2>&1; then
    log "Enabling SDDM display manager..."
    sudo systemctl enable sddm.service
  fi

  # Enable NetworkManager for WiFi
  if command -v NetworkManager >/dev/null 2>&1 || pacman -Qi networkmanager >/dev/null 2>&1; then
    log "Enabling NetworkManager for WiFi..."
    sudo systemctl enable NetworkManager.service
    sudo systemctl start NetworkManager.service || true
  else
    log "NetworkManager not installed - WiFi setup skipped."
    if confirm "Install NetworkManager now for WiFi support?"; then
      sudo pacman -S --needed --noconfirm networkmanager
      sudo systemctl enable NetworkManager.service
      sudo systemctl start NetworkManager.service || true
    fi
  fi

  # Enable Bluetooth if installed
  if pacman -Qi bluez >/dev/null 2>&1; then
    log "Enabling Bluetooth service..."
    sudo systemctl enable bluetooth.service
    sudo systemctl start bluetooth.service || true
  fi

  # Add user to necessary groups
  local current_user
  current_user=$(id -un)
  log "Adding user '$current_user' to video, audio, input groups..."
  sudo usermod -aG video,audio,input "$current_user" 2>/dev/null || log "Some groups may already be assigned."

  # Enable PipeWire services for current user
  if command -v pipewire >/dev/null 2>&1; then
    log "Enabling PipeWire audio services for user session..."
    systemctl --user enable pipewire.service pipewire-pulse.service 2>/dev/null || true
  fi

  log "Service configuration complete."
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

  echo
  log "Package installation complete."
  echo
  if confirm "Do you want to use dotfiles from github.com/madmax3553/dotfiles?"; then
    clone_dotfiles
    apply_dotfiles_stow
  else
    log "Skipping dotfiles - using vanilla configs."
  fi

  echo
  log "Configuring system services..."
  configure_services

  log "GArchy Stage 1 complete. Reboot to start SDDM/Hyprland session."
}

main "$@"
