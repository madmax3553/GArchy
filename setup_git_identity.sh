#!/usr/bin/env bash
#
# GArchy helper: configure global git identity and basic settings.
# Intended to be run once per user after first boot.

set -euo pipefail

log() {
  printf '\e[32m[GArchy/git]\e[0m %s\n' "$*" >&2
}

err() {
  printf '\e[31m[GArchy/git]\e[0m %s\n' "$*" >&2
}

require_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    err "Do not run this as root. Run it as your normal user."
    exit 1
  fi
}

setup_git_identity() {
  local existing_name existing_email
  existing_name=$(git config --global user.name || true)
  existing_email=$(git config --global user.email || true)

  echo
  log "Configuring global git identity..."

  if [[ -n "$existing_name" || -n "$existing_email" ]]; then
    echo "Current git identity:"
    [[ -n "$existing_name" ]] && echo "  user.name  = $existing_name"
    [[ -n "$existing_email" ]] && echo "  user.email = $existing_email"
    read -rp "Do you want to change it? [y/N]: " change
    if [[ ! "$change" =~ ^[Yy]$ ]]; then
      log "Leaving existing git identity unchanged."
      return 0
    fi
  fi

  local default_name="${USER:-groot}"

  read -rp "Enter git user.name [${default_name}]: " git_name
  git_name=${git_name:-$default_name}

  read -rp "Enter git user.email (e.g. you@example.com): " git_email

  if [[ -z "$git_email" ]]; then
    err "user.email is required for most git hosting services; leaving it unset."
    echo "You can set it later with:"
    echo "  git config --global user.email 'you@example.com'"
  else
    git config --global user.email "$git_email"
  fi

  git config --global user.name "$git_name"
  git config --global init.defaultBranch main

  log "Global git identity configured."
}

print_git_tips() {
  echo
  log "Optional: additional git configuration tips:"
  echo "  # Cache HTTPS credentials in memory for 15 minutes (example):"
  echo "  git config --global credential.helper 'cache --timeout=900'"
  echo
  echo "  # Or store HTTPS credentials on disk (be aware of security implications):"
  echo "  git config --global credential.helper store"
  echo
  echo "  # If you prefer SSH for GitHub, you can run:"
  echo "  ssh-keygen -t ed25519 -C 'your_email@example.com'"
  echo "  # Then add ~/.ssh/id_ed25519.pub to GitHub."
}

main() {
  require_not_root
  setup_git_identity
  print_git_tips
  log "Done."
}

main "$@"
