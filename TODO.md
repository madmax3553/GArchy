# TODO — pick up here

## FIRST: no SSH access to the live ISO (symptom confirmed)

User booted the ISO but could not SSH in. Debug order:
1. Did the machine even get on the network? No wifi creds in the live env —
   sshd is useless without a link. If target is wifi-only, the live ISO needs
   a baked-in NM/iwd profile (like stage0's --wifi) — likely the root cause
   if there's no ethernet plugged in.
2. Was sshd actually enabled? Verify the symlink lands correctly:
   `airootfs/etc/systemd/system/multi-user.target.wants/sshd.service`
   (releng may already autostart sshd via cloud-init/other — check).
3. Key auth: releng root has empty password; sshd denies empty-password +
   PermitRootLogin default is prohibit-password → key-only. Were the baked
   authorized_keys present with right perms? Check profiledef.sh insertion.
4. Was the right key offered from this machine? (`ssh -v root@<ip>`)
5. Could also be it never booted properly (copytoram=y sed edits) — verify
   boot entries as below.

## Broken: ISO boot didn't work (reported Aug 16)

Context / current state:
- `build-iso.sh` recently changed: sshd enabled in live env, SSH pubkeys baked
  into root authorized_keys, optional `GARCHY_LIVE_ROOT_PW`, and `copytoram=y`
  added to systemd-boot entries, syslinux cfgs, and grub.cfg.
- Prime suspects to check first:
  1. `copytoram=y` sed edits — verify they didn't corrupt boot entries:
     inspect `archiso-work/garchy/efiboot/loader/entries/*.conf`,
     `syslinux/*.cfg`, `grub/grub.cfg` after `prepare_profile` runs.
  2. If written directly to the SSD: was there enough RAM for copytoram
     (needs ISO size + working set)?
  3. profiledef.sh `file_permissions` insertion for /root/.ssh — syntax OK?
  4. How did it fail? (no boot menu / kernel panic / dropped to emergency /
     no ssh?) — get symptoms from user.
- Debug without full rebuild: run just `prepare_profile` and diff the
  profile dir against stock releng.

## Also outstanding
- SSD (`/dev/sda`, 1TB) stage0 re-run status unknown — user re-ran
  `stage0-install.sh --from-host` after the interrupted attempt; confirm it
  completed and whether `--wifi NachoWiFi` was included.
- After target boots: `ssh groot@<ip or garchy>` (pw `archlinux`, change
  forced), then `cd ~/GArchy && ./stage1-setup.sh`.
- Optional: no LAN scanner installed yet (`nmap` / `netscanner`) if needed
  to find the target's IP.
- Dotfiles: SSH/GPG keys were purged from repo history (private repo);
  rotation optional. Backup bundle: /tmp/opencode/dotfiles-pre-purge.bundle
  (tmp — may not survive reboot).
