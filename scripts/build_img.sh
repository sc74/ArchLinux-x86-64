#!/usr/bin/env bash
set -euo pipefail

# Assembles the bootable x86-64 disk image (BIOS + UEFI) from the rootfs tarball of the Docker
# build. Two partitions: /boot (FAT32, kernel + initramfs + GRUB) and / (ext4).
# Needs sudo, sfdisk, losetup, mkfs.vfat, mkfs.ext4, blkid and tar on the host; grub and
# mkinitcpio are the ones of the rootfs, used in a chroot.

# --- settings ---
BOARD=${BOARD:-pc}
IMG=${IMG:-archlinux-${BOARD}-x86_64.img}
SIZE=${SIZE:-20G}         # total image size
BOOT_MB=${BOOT_MB:-512}   # /boot (FAT32, also the EFI System Partition) size in MiB
ROOT_LABEL=${ROOT_LABEL:-ASTROARCH_ROOT}   # ext4 label, 16 characters at most
BOOT_LABEL=${BOOT_LABEL:-ASTROARCH_B}      # FAT label, 11 characters at most (ASTROARCH_BOOT is 14)
ROOTFS_TAR=${ROOTFS_TAR:-rootfs.tar}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOARD_CONF="${SCRIPT_DIR}/../boards/${BOARD}.conf"

# --- board profile: BOOT_START (sectors), BOOT_MB, CONSOLE ---
[ -f "$BOARD_CONF" ] || { echo "Unknown BOARD=$BOARD (no $BOARD_CONF)"; exit 1; }
# shellcheck disable=SC1090
source "$BOARD_CONF"

# sanity
[ -f "$ROOTFS_TAR" ] || { echo "Missing $ROOTFS_TAR"; exit 1; }
[ "${#BOOT_LABEL}" -le 11 ] || { echo "BOOT_LABEL '$BOOT_LABEL' is longer than 11 characters, the limit of a FAT label"; exit 1; }
[ "${#ROOT_LABEL}" -le 16 ] || { echo "ROOT_LABEL '$ROOT_LABEL' is longer than 16 characters, the limit of an ext4 label"; exit 1; }
for tool in sfdisk losetup blkid mkfs.vfat mkfs.ext4; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

ROOT=/mnt/astro-root
LOOP=""

# --- always unmount and detach, also when something fails halfway ---
cleanup() {
  set +e
  sudo umount -R "$ROOT" 2>/dev/null
  [ -n "$LOOP" ] && sudo losetup -d "$LOOP"
}
trap cleanup EXIT

# --- create sparse disk file ---
truncate -s "$SIZE" "$IMG"

# --- partition table (MBR): /boot (FAT32, type ef = EFI System Partition, active) then the ext4 root ---
BOOT_SIZE=$(( BOOT_MB * 2048 ))               # sectors (MiB * 2048)
sfdisk "$IMG" <<EOF2
label: dos
unit: sectors
${IMG}1 : start=${BOOT_START}, size=${BOOT_SIZE}, type=ef, bootable
${IMG}2 : start=$((BOOT_START+BOOT_SIZE)), type=83
EOF2

# --- map loop with partitions ---
LOOP=$(sudo losetup --find --show --partscan "$IMG")
BOOT_DEV=${LOOP}p1
ROOT_DEV=${LOOP}p2

# --- mkfs ---
sudo mkfs.vfat -F 32 -n "$BOOT_LABEL" "$BOOT_DEV"
sudo mkfs.ext4 -F -L "$ROOT_LABEL" "$ROOT_DEV"

BOOT_UUID=$(sudo blkid -s UUID -o value "$BOOT_DEV")
ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_DEV")

# --- mount the root, extract the rootfs (preserve owners) ---
sudo mkdir -p "$ROOT"
sudo mount "$ROOT_DEV" "$ROOT"
sudo tar --numeric-owner -xpf "$ROOTFS_TAR" -C "$ROOT"

# --- /boot is its own partition: FAT32 cannot hold owners, modes or symlinks, so the content of
# the rootfs' /boot (kernel, initramfs, microcode) is copied onto it instead of extracted there ---
sudo mv "$ROOT/boot" "$ROOT/boot.stage"
sudo mkdir "$ROOT/boot"
sudo mount "$BOOT_DEV" "$ROOT/boot"
sudo cp -rL --no-preserve=all "$ROOT/boot.stage/." "$ROOT/boot/"
sudo rm -rf "$ROOT/boot.stage"

# The rootfs tarball leaves out /dev /proc /sys /run /mnt /media: they are mount points, created
# here (needed by the chroot below, and by the first boot)
sudo install -d -m 0755 "$ROOT/dev" "$ROOT/run" "$ROOT/mnt" "$ROOT/media"
sudo install -d -m 0555 "$ROOT/proc" "$ROOT/sys"
sudo install -d -m 1777 "$ROOT/tmp" "$ROOT/var/tmp"

# --- hostname & hosts (cannot be set during Docker build) ---
echo "astroarch" | sudo tee "$ROOT/etc/hostname" >/dev/null
printf '127.0.0.1\tlocalhost\n127.0.1.1\tastroarch\n' | sudo tee -a "$ROOT/etc/hosts" >/dev/null

# --- DNS of the first boot, before NetworkManager takes over (the file copied from the
# Docker build is the one of the builder) ---
sudo rm -f "$ROOT/etc/resolv.conf"
sudo install -m644 "${SCRIPT_DIR}/../configs/resolv.conf" "$ROOT/etc/resolv.conf"

# --- build "console=X" args from the board's (possibly multi-value) CONSOLE ---
CONSOLE_ARGS=""
for c in $CONSOLE; do
  CONSOLE_ARGS="${CONSOLE_ARGS}console=${c} "
done
CONSOLE_ARGS="${CONSOLE_ARGS% }"

# --- fstab: UUIDs, so device names don't matter ---
sudo tee "$ROOT/etc/fstab" <<EOF2
UUID=${ROOT_UUID}  /          ext4   defaults,noatime   0 1
UUID=${BOOT_UUID}  /boot      vfat   umask=0077         0 2
EOF2

# --- chroot: the rootfs has its own grub and mkinitcpio, the build machine needs neither ---
# slave mounts: unmounting them later must not reach the /dev of this machine
sudo mount --rbind /dev "$ROOT/dev" && sudo mount --make-rslave "$ROOT/dev"
sudo mount -t proc proc "$ROOT/proc"
sudo mount -t sysfs sys "$ROOT/sys"

# A generic initramfs. The default "autodetect" hook keeps only the drivers of the machine that
# builds it, and this image has to boot on any PC. No fallback image: this one is the fallback
sudo install -d "$ROOT/etc/mkinitcpio.conf.d"
sudo tee "$ROOT/etc/mkinitcpio.conf.d/astroarch.conf" >/dev/null <<EOF2
MODULES=(ext4 vfat)
HOOKS=(base udev modconf kms keyboard keymap block filesystems fsck)
COMPRESSION="zstd"
EOF2
sudo sed -i "s/^PRESETS=.*/PRESETS=('default')/" "$ROOT/etc/mkinitcpio.d/linux.preset"
sudo rm -f "$ROOT"/boot/initramfs-linux-fallback.img
sudo chroot "$ROOT" mkinitcpio -P

# BIOS: boot code in the gap before partition 1 + core image on the root
sudo chroot "$ROOT" grub-install --target=i386-pc --recheck "$LOOP"
# UEFI: /boot is the ESP; removable location (EFI/BOOT/BOOTX64.EFI), no NVRAM entry to write
sudo chroot "$ROOT" grub-install --target=x86_64-efi --efi-directory=/boot --removable --no-nvram

# Static grub.cfg: the kernel and the initramfs keep their names across upgrades, so it never
# has to be regenerated (grub-mkconfig does not work well in a chroot over a loop device).
# GRUB reads it from the /boot partition, which is therefore GRUB's root: the paths below are
# relative to it (/vmlinuz-linux is /boot/vmlinuz-linux once the system runs).
# Hidden menu, 1 second: Esc shows it, for the console entry.
INITRDS=""
for ucode in amd-ucode intel-ucode; do
  [ -f "$ROOT/boot/$ucode.img" ] && INITRDS="$INITRDS /$ucode.img"
done
INITRDS="$INITRDS /initramfs-linux.img"
sudo tee "$ROOT/boot/grub/grub.cfg" >/dev/null <<EOF2
set default=0
set timeout=1
set timeout_style=hidden

menuentry "AstroArch" {
    linux  /vmlinuz-linux root=UUID=${ROOT_UUID} rw rootwait ${CONSOLE_ARGS} quiet loglevel=3 fsck.repair=yes
    initrd${INITRDS}
}

menuentry "AstroArch (console)" {
    linux  /vmlinuz-linux root=UUID=${ROOT_UUID} rw rootwait ${CONSOLE_ARGS} systemd.unit=multi-user.target
    initrd${INITRDS}
}
EOF2

sync

# --- unmount & detach (the ESP and the chroot mounts are all under the root) ---
sudo umount -R "$ROOT"
sudo losetup -d "$LOOP"
LOOP=""

echo "OK: ${IMG} is ready."
