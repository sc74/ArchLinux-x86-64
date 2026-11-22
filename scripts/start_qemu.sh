#!/usr/bin/env bash
# Boots the image in QEMU, in BIOS or in UEFI mode (no sudo, no loop device needed).
#   ./scripts/start_qemu.sh [image]            BIOS (SeaBIOS)
#   MODE=uefi ./scripts/start_qemu.sh [image]  UEFI (OVMF); OVMF=/path/to/OVMF.fd if not found
# ssh: ssh -p 2222 astronaut@localhost ; VNC of the desktop: localhost:5900
set -euo pipefail

IMG=${1:-archlinux-pc-x86_64.img}
MODE=${MODE:-bios}
[ -f "$IMG" ] || { echo "Missing $IMG"; exit 1; }

args=(-m "${MEM:-4096}" -smp "${CPUS:-4}"
      -drive file="$IMG",format=raw,if=virtio
      -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22,hostfwd=tcp::5900-:5900
      -device virtio-vga)

if [ -w /dev/kvm ]; then args+=(-enable-kvm -cpu host); else args+=(-cpu max); fi

if [ "$MODE" = uefi ]; then
  if [ -z "${OVMF:-}" ]; then
    for f in /usr/share/edk2/x64/OVMF.4m.fd /usr/share/edk2/x64/OVMF.fd /usr/share/ovmf/OVMF.fd \
             /usr/share/OVMF/OVMF.fd /usr/share/qemu/OVMF.fd /usr/share/edk2/ovmf/OVMF.fd; do
      [ -f "$f" ] && OVMF=$f && break
    done
  fi
  [ -n "${OVMF:-}" ] || { echo "OVMF firmware not found: install edk2-ovmf (Arch) or ovmf (Debian), or set OVMF="; exit 1; }
  args+=(-bios "$OVMF")
fi

exec qemu-system-x86_64 "${args[@]}"
