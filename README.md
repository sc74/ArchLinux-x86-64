# ArchLinux x86-64 Docker Builder

Reproducible Arch Linux x86-64 root filesystems and bootable disk images for AstroArch on PCs and
mini PCs, driven entirely by Docker Buildx. Sister project of
[ArchLinuxARM](https://github.com/devDucks/ArchLinuxARM) (aarch64 images): same layout, same
philosophy, one repository per architecture. The AstroArch system itself lives in
[astroarch](https://github.com/devDucks/astroarch), shared by both.

## Overview

The build is native x86-64, nothing is emulated. Two images are produced:

| Image | Description |
|---|---|
| **base** | The official `archlinux` image with pacman set up for containers, the Arch keyring, `openssh` (sshd enabled), `curl`, `wget`, `nano`, `dbus`. |
| **astroarch** | The base plus KDE Plasma (Wayland) and the astrophotography stack (KStars/Ekos, INDI, PHD2, astrometry.net index files) and remote access, installed by `astroarch_build.sh` from the `astroarch` repository (`packages.txt` + `packages-x86.txt`). |

The astroarch rootfs can be exported as a tarball and converted into a bootable `.img`.

## Requirements

- Docker with Buildx
- For image creation (Linux only, requires `sudo`): `sfdisk`, `losetup`, `mkfs.vfat`, `mkfs.ext4`, `blkid`
- To test the image: `qemu-system-x86_64` (and OVMF for UEFI)

## Quick start

```bash
git clone git@github.com:devDucks/ArchLinux-x86-64.git
cd ArchLinux-x86-64
```

Check which packages of AstroArch exist for x86_64 (official repos + astromatto):

```bash
make check-packages ASTROARCH_DIR=../astroarch
```

Build the base image, then AstroArch (KDE Plasma + astrophotography stack):

```bash
make build-base
make build-astroarch
```

Build the bootable image:

```bash
make prepare-img                      # archlinux-pc-x86_64.img
```

To build a fork or a branch of `astroarch`:

```bash
make prepare-img ASTROARCH_REPO=https://github.com/<you>/astroarch.git \
                 ASTROARCH_BRANCH=<branch>
```

Test it, then flash it:

```bash
./scripts/start_qemu.sh               # BIOS
MODE=uefi ./scripts/start_qemu.sh     # UEFI
sudo dd if=archlinux-pc-x86_64.img of=/dev/sdX bs=4M status=progress
sync
```

## Make targets

| Target | Description |
|---|---|
| `build-base` | Base image (`dockerfiles/Dockerfile.base`), tagged `archlinux-x86-64:latest`. |
| `build-astroarch` | AstroArch image (`dockerfiles/Dockerfile.astroarch`, `builder` target). |
| `build-astroarch-rootfs` | Builds the AstroArch rootfs image (`astroarch-x86-64-rootfs:latest`). |
| `create-rootfs-container` | Creates a throwaway container from it to extract its filesystem. |
| `copy-rootfs-tar` | Copies `astroarch-rootfs.tar` out of that container into `./rootfs.tar` and removes it. |
| `check-packages ASTROARCH_DIR=<path>` | Lists the packages not available for x86_64. |
| `prepare-img [BOARD=pc]` | Builds the rootfs, then runs `scripts/build_img.sh` to produce `archlinux-<board>-x86_64.img`. |

## The disk image

`scripts/build_img.sh` builds a disk that boots in **BIOS and UEFI** (profile in `boards/pc.conf`):

- MBR partition table. Partition 1: EFI System Partition (512 MiB, FAT32, mounted on `/boot/efi`).
  Partition 2: ext4 root. The kernel, the initramfs and `grub.cfg` are on the root, in `/boot`.
- GRUB is installed twice, in a chroot of the rootfs (its own grub and mkinitcpio, the build
  machine needs neither): `i386-pc` for BIOS and `x86_64-efi` in the removable location
  `EFI/BOOT/BOOTX64.EFI` (no NVRAM entry, so the disk boots on any machine).
- `grub.cfg` is static and the menu is hidden (1 second, Esc shows it): the machine boots straight to
  the display manager, which logs `astronaut` in. Kernel upgrades need no `grub-mkconfig`; after an
  upgrade of the `grub` package a pacman hook of `astroarch` rewrites the boot code.
- The initramfs has no `autodetect` hook, so it holds the drivers of any PC, not only of the
  build machine.
- Secure Boot is not supported (GRUB is not signed): disable it in the firmware.
- The image is sparse, 20 GB by default (`SIZE=`); the root grows to the whole disk at the first boot
  (`resize_once.service`).

A new board profile is a `boards/<name>.conf` setting `BOOT_START`, `BOOT_MB` and `CONSOLE`
(for example a serial console: `CONSOLE="ttyS0,115200 tty0"`), no change to the script.

## Default credentials

| Image | User | Password |
|---|---|---|
| AstroArch | `astronaut` | `astro` |

SSH is enabled. root has no password. Change the credentials before exposing the image on an
untrusted network.

## CI/CD

- `.github/workflows/buildx.yml` builds and pushes the base image to GHCR (`ghcr.io/<owner>/archlinux-x86-64`)
  on pushes to `main`, on version tags, weekly and on manual dispatch; the AstroArch image
  (`ghcr.io/<owner>/astroarch-x86-64`) weekly and on manual dispatch. Pull requests build without pushing.
- `.github/workflows/build-image.yml` builds the bootable image, shrinks it with PiShrink and
  attaches it to a release for tags `img-v*` (artifact for a manual run).

## Project layout

```
.
├── boards/
│   └── pc.conf
├── configs/
│   └── resolv.conf
├── dockerfiles/
│   ├── Dockerfile.base
│   └── Dockerfile.astroarch
├── scripts/
│   ├── build_img.sh
│   ├── check-packages.sh
│   └── start_qemu.sh
├── Makefile
└── README.md
```

## License

[GPL-3.0](./LICENSE)
