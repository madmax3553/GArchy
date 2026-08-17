# GArchy – My Arch Spin

GArchy is my personal Arch Linux spin:

- **Stage 0** – Full-disk Arch installer, run from the Arch ISO.
- **Stage 1** – Desktop + packages + dotfiles for my user.
- **Git helper** – Optional first-boot script to set git identity.
- **ISO builder** – Optional script to build a custom GArchy ISO using `archiso`.

---

## 0. Requirements

- UEFI system (GPT partitioning).
- OK with wiping an entire disk (Stage 0 will destroy all data on the selected drive).
- Arch Linux official ISO (for the basic flow).
- Network connectivity from the live ISO.

---

## 1. Quick Start (using the official Arch ISO)

### 1.1 Boot the Arch ISO

1. Download the latest Arch ISO from [archlinux.org](https://archlinux.org/download/).
2. Flash to USB (e.g. `dd`, `Rufus`, `Ventoy`, etc.).
3. Boot from USB into the Arch live environment.

### 1.2 Get network and tools in the live ISO

In the Arch ISO shell, as `root`:

```bash
# 1. Get network up
# If Ethernet, it's usually already fine.

# If Wi-Fi with iwd:
iwctl              # then use 'station <dev> connect <SSID>'

# or use your preferred method.
```

Then install `git` and `networkmanager` in the **live** environment:

```bash
pacman -Sy --needed git networkmanager
systemctl start NetworkManager   # optional but convenient
```

### 1.3 Clone and run Stage 0 installer

```bash
git clone https://github.com/madmax3553/GArchy /root/GArchy
cd /root/GArchy
chmod +x stage0-install.sh
./stage0-install.sh
```

`stage0-install.sh` will:

- List available disks and ask you to choose one to **wipe** (e.g. `/dev/nvme0n1`).
- Ask for:
  - `hostname` (default: `garchy`)
  - `username` (default: `groot`)
- Partition the selected disk (GPT):
  - EFI partition (512 MiB, FAT32)
  - Root partition (rest, ext4) – swap via **zram** (`zram-generator`).
- `pacstrap` a minimal Arch system with:
  - `base`, `linux` (or `linux-surface`), `linux-firmware`
  - `amd-ucode` / `intel-ucode` (auto-detected; override with `--ucode`)
  - `grub`, `efibootmgr`, `zram-generator`
  - `networkmanager`, `openssh`, `sudo`, `git`
  - `greetd`, `hyprland`, `uwsm`, `reflector`, `bash-completion`
- **Surface Support**: Optional `linux-surface` kernel and repository integration for Microsoft Surface devices.
- Configure:
  - Hostname, `/etc/hosts`
  - Timezone: `Canada/Eastern` (adjust later if needed)
  - Locale: `en_US.UTF-8`
- Install GRUB (UEFI, `--removable` so the disk boots on any machine).
- Create user (default `groot`) in `wheel`, enable `sudo` for `wheel`.
- Enable services:
  - `NetworkManager`
  - `sshd`
  - `greetd`
- Clone `GArchy` into `/home/<user>/GArchy`.

When Stage 0 completes, it will tell you to reboot into the new system.

### 1.4 Headless install to an attached SSD (`--from-host`)

You don't need the ISO or a monitor at all: attach the target SSD to an
existing Arch machine (USB adapter is fine) and install directly onto it:

```bash
sudo ./stage0-install.sh --from-host --disk /dev/sdX --ucode amd --hostname garchy --user groot
```

Flags:

- `--from-host` – run from a normal Arch system instead of the live ISO.
- `--disk` – target disk (skips the interactive disk prompt).
- `--ucode amd|intel|both` – microcode for the **target** machine's CPU
  (auto-detect uses the host CPU, which may be wrong when cross-installing).
- `--hostname`, `--user`, `--surface` – skip the corresponding prompts.

Then move the SSD to the target machine and power it on. It boots straight
into the installed system with DHCP + sshd enabled:

```bash
ssh groot@<target-ip>     # password: archlinux (change forced on first login)
cd ~/GArchy && ./stage1-setup.sh
```

---

## 2. Stage 1 – Desktop, packages, and dotfiles

After reboot, log into your new system as the user you created (default: `groot`).

### 2.1 Run Stage 1

```bash
cd ~/GArchy
chmod +x stage1-setup.sh
./stage1-setup.sh
```

What Stage 1 does:

1. **Safety checks**
   - Must be run on Arch.
   - Must *not* be run as root.

2. **Refresh mirrorlist (Canada, HTTPS)**
   - Installs `reflector` if needed.
   - Runs:
     ```bash
     reflector \
       --country 'Canada' \
       --latest 20 \
       --protocol https \
       --sort rate \
       --save /etc/pacman.d/mirrorlist
     ```

3. **Install repo packages (pacman)**

   Package lists live in:

   - `packages/mandatory.txt`
   - `packages/default.txt`
   - `packages/optional/*.txt` (e.g. `gui.txt`, `dev.txt`, `theme.txt`, `tools.txt`)

   Behavior:

   - **Mandatory**: printed, then installed **without prompt**.
   - **Default**: printed, then you’re asked whether to install.
   - **Optional**: for each `packages/optional/*.txt`, printed, then you’re asked whether to install that group.

   `mandatory.txt` includes things like:

   - Core tools: `git`, `stow`, `bash`, `zoxide`, `eza`, `starship`, `reflector`.
   - Terminal FM: `mc`.
   - Editor: `neovim`.
   - Terminals: `kitty` (and `ghostty` via AUR later).
   - CLI tools: `htop`, `ripgrep`, `fd`, `bat`, `fzf`.
   - Browsers: `qutebrowser`.
   - Hyprland stack: `hyprland`, `hypridle`, `hyprlock`, `swaync`, `libnotify`, portals.
   - Qt Wayland: `qt5-wayland`, `qt6-wayland`.
   - Launcher: `tofi`.
   - Bar: `waybar`.
   - Audio: `pipewire`, `pipewire-pulse`, `wireplumber`, `alsa-utils`.
   - Display manager: `greetd` + `uwsm` (`sysc-greet-hyprland` greeter from AUR).
   - Font: `ttf-hack-nerd`.

4. **Install AUR packages (yay)**

   AUR lists live in:

   - `packages/aur-mandatory.txt`
   - `packages/aur-default.txt`
   - `packages/aur-optional.txt`

   Behavior:

   - Installs `yay-bin` from AUR (via `base-devel + git + makepkg`).
   - **AUR Mandatory**: printed and installed **without prompt** (e.g. `yay-bin`, `google-chrome`, `waypaper`).
   - **AUR Default**: printed, then prompt (e.g. `zen-browser-bin`, `grimblast-git`, `swaync-widgets-git`, `wlogout`).
   - **AUR Optional**: printed, then prompt (large list of dev tools, ASTAL libs, games, etc.).

5. **Clone and apply dotfiles**

   - Clones (or updates) `https://github.com/madmax3553/dotfiles` into `~/dotfiles`.
   - Applies via `stow`, but **only for tools that are installed**.

   The mapping (inside `stage1-setup.sh`) looks like:

   ```bash
   declare -A STOW_REQUIRE_CMDS=(
     [bash]=""           # always stow shell config
     [bin]=""            # always stow scripts
     [nvim]="nvim"
     [hypr]="Hyprland"
     [rofi]="rofi tofi"
     [yazi]="yazi"
     [ranger]="ranger"
     [qtile]="qtile"
     # [theme]=""        # add if you have a theming package
     # [wallpapers]=""   # add if you have wallpapers-only stow dir
   )
   ```

   For each stow package:

   - If its folder exists in `~/dotfiles` and its required commands (if any) are installed, it runs:
     ```bash
     stow -R <package>
     ```
   - Otherwise, it logs that it’s skipped.

This means you can keep extra configs in `dotfiles` while cleaning up over time; they won’t be stowed unless the corresponding software is actually installed.

---

## 3. Optional: Git identity helper

Instead of baking git prompts into Stage 1, there is a separate helper:

```bash
cd ~/GArchy
chmod +x setup_git_identity.sh
./setup_git_identity.sh
```

What it does:

- Ensures you’re not root.
- If a global git identity is already set, it shows it and asks if you want to change it.
- Prompts for:
  - `user.name` (default: current login, e.g. `groot`)
  - `user.email`
- Sets:
  ```bash
  git config --global user.name "<name>"
  git config --global user.email "<email>"
  git config --global init.defaultBranch main
  ```
- Prints tips about:
  - Using `credential.helper cache` or `store` for HTTPS.
  - Generating an SSH key and adding it to GitHub.

You run this **once per user** on a new system.

---

## 4. Optional: Build a custom GArchy ISO

Once you have an Arch system running (not the live ISO), you can build a custom GArchy ISO with `archiso`.

### 4.1 Install archiso

```bash
sudo pacman -Syu --needed archiso
```

### 4.2 Build the ISO

```bash
git clone https://github.com/madmax3553/GArchy ~/GArchy   # if not already cloned
cd ~/GArchy
chmod +x build-iso.sh
./build-iso.sh
```

`build-iso.sh` will:

- Copy Arch’s official `releng` archiso profile into `./archiso-work/garchy`.
- Copy the `GArchy` repo into the ISO under `/usr/local/share/GArchy`.
- Enable **sshd** in the live environment and bake in your `~/.ssh/*.pub` keys
  as root's `authorized_keys` (headless SSH access to the live system).
- Optionally set a live root password: `GARCHY_LIVE_ROOT_PW=secret ./build-iso.sh`
  (also enables SSH password auth in the live env).
- Add `copytoram=y` to all boot entries, so the live system runs entirely from
  RAM — you can `dd` the ISO **directly onto the target SSD** and then wipe
  that same SSD from stage0 (needs ~4 GB+ RAM).
- Drop a `/root/GARCHY-INSTALL.txt` in the live image with simple instructions.
- Run `mkarchiso` to produce an ISO under `./out/`.

You can then flash `./out/*.iso` to USB — or directly to the target disk —
and boot from it. For a fully headless install: boot the ISO, wait for DHCP,
then `ssh root@<ip>` and run `/usr/local/share/GArchy/stage0-install.sh`.

On your custom GArchy ISO, the rough live usage is:

```bash
# In live environment as root:

# If needed, start NetworkManager and connect:
systemctl start NetworkManager
nmcli device wifi connect "SSID" password "..."

cd /usr/local/share/GArchy
./stage0-install.sh
```

(You can further customize the archiso profile to auto-install `git`, `networkmanager`, etc. into the live environment and change prompts as you like.)

---

## 5. Notes & TODOs

- **Surface Devices**: Stage 0 now prompts if you're on a Surface device. If 'y', it installs the `linux-surface` kernel and configures the repository.
- **Niri Compositor**: Added optional package lists for Niri. You can install them during Stage 1 and they will be automatically configured if your dotfiles repo contains a `niri` folder.
- Timezone in Stage 0 is hardcoded to `Canada/Eastern`. Change `/etc/localtime` symlink there if you want a different default.
- Swap is via zram (`zram-generator`, `zram-size = ram`, zstd).
- If you add or remove tools from your stack:
  - Update `packages/*.txt` accordingly.
  - Update `STOW_REQUIRE_CMDS` in `stage1-setup.sh` if you add new stow packages.
- For Wayland utilities and themes, see:
  - `packages/optional/theme.txt`
  - `packages/optional/tools.txt`

---

## 6. Typical end-to-end flow

1. Boot **Arch ISO**.
2. Enable network, install `git` + `networkmanager` in live ISO.
3. Clone GArchy and run `stage0-install.sh`.
4. Reboot into the new system.
5. As your user (default `groot`):
   - `./stage1-setup.sh`
   - `./setup_git_identity.sh` (optional)
6. Log in via greetd → Hyprland and enjoy GArchy.
