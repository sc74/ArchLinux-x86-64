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

`scripts/build_img.sh` builds a disk that boots in **BIOS and UEFI** (profile in `boards/pc.conf`), with
two partitions and an MBR partition table:

| Partition | Mounted on | Filesystem | Label | Content |
|---|---|---|---|---|
| 1 | `/boot` | FAT32, 1 GiB | `ASTROARCH_B` | kernel, initramfs, microcode, GRUB (UEFI reads it too) |
| 2 | `/` | ext4, rest of the disk | `ASTROARCH_ROOT` | the system |

- A FAT label holds 11 characters at most, so `ASTROARCH_BOOT` is not possible for partition 1. It is
  `ASTROARCH_B`; change it with `BOOT_LABEL=` (11 characters at most). The ext4 label is
  `ASTROARCH_ROOT` (`ROOT_LABEL=`).
- GRUB is installed twice, in a chroot of the rootfs (its own grub and mkinitcpio, the build
  machine needs neither): `i386-pc` for BIOS and `x86_64-efi` in the removable location
  `EFI/BOOT/BOOTX64.EFI` (no NVRAM entry, so the disk boots on any machine).
- `grub.cfg` is static and the menu is hidden (1 second, Esc shows it): the machine boots straight to
  the display manager, which logs `astronaut` in. Kernel upgrades need no `grub-mkconfig`; after an
  upgrade of the `grub` package a pacman hook of `astroarch` rewrites the boot code.
- The initramfs has no `autodetect` hook, so it holds the drivers of any PC, not only of the
  build machine.
- `/boot` has MBR type `c` (FAT32 LBA), not `ef`: it is not flagged "esp", so file managers show it. Some strict
  UEFI firmwares only look at type `ef`; if yours does not find the disk, build with `BOOT_PART_TYPE=ef`.
- By default GRUB is not signed: with Secure Boot on, UEFI stops with "Invalid signature detected" or
  "Access Denied". Either disable Secure Boot in the firmware, or build the image with Secure Boot
  support (next section).
- The image is sparse, 20 GB by default (`SIZE=`); the root grows to the whole disk at the first boot
  (`resize_once.service`).

A new board profile is a `boards/<name>.conf` setting `BOOT_START`, `BOOT_MB` and `CONSOLE`
(for example a serial console: `CONSOLE="ttyS0,115200 tty0"`), no change to the script.

## Secure Boot (shim + a key enrolled once)

A firmware only trusts what Microsoft signed, so the image starts **shim** (signed by Microsoft), which starts
GRUB and the kernel signed with *your* key (a Machine Owner Key, MOK). The PC keeps Secure Boot on (Windows
is not touched) and trusts your key after one confirmation in MokManager, once per machine.

```bash
./scripts/gen-mok.sh                      # secureboot/MOK.key (secret), MOK.crt, MOK.cer
make prepare-img SECURE_BOOT=1            # build with shim, signed GRUB and kernel
```

First boot of the disk, with Secure Boot on: shim shows "Verification failed (0x1A) Security Violation" and
opens MokManager ("Perform MOK management"):

1. **Enroll key from disk**, then the partition of the disk (the one with `EFI`), then **`MOK.cer`**;
2. confirm (**Yes**), then **Continue** / **Reboot**;
3. boot the disk again: shim, GRUB and the kernel now start. Nothing more to do, also after updates.

- **Updates:** `sbsigntools` and pacman hooks (`astroarch` repo: `scripts/x86/secureboot.sh`) sign the new kernel
  and rebuild the signed GRUB on the machine, with the key kept in `/etc/astroarch/secureboot/`.
- **The private key is inside the image** (`SB_EMBED_KEY=1`, the default), which is what makes the updates work
  without anything to do. So **anyone who has the image can sign code that this key makes trusted**: build it for
  your own machines, with your own key, and do not publish it. With `SB_EMBED_KEY=0` the key stays out of the image,
  but the kernels installed by `pacman` are not signed any more and the PC stops booting after a kernel update.
- **CI:** with the repository secrets `MOK_KEY` and `MOK_CRT` the workflow builds with Secure Boot. Such an image
  is kept as an artifact and not attached to a release (it contains the key).
- **SBAT:** shim refuses a GRUB whose SBAT generation is below its revocation policy, even when the key is
  enrolled (and MokManager comes back with the same "Verification failed"). The Arch `sbat.csv` can declare an
  older generation (`grub,4`) than the GRUB it ships: `grub-mkimage` reports its own build-time level in a warning
  ("Global SBAT level 5 in sbat.csv does not match the build-time Global SBAT level 6"), and `secureboot.sh` uses
  that level. `SBAT_GRUB_MIN` (default 5) is a floor for a shim that asks for more. Check what the shim asks with
  `objcopy -O binary --only-section=.sbatlevel BOOTX64.EFI /dev/stdout | tr -c '[:print:]\n' '.'`.
- **shim:** it comes from the AUR (`shim-signed-bin`), built during the Docker build. The Microsoft CA 2011 expired
  in June 2026 and older shims were revoked: use a recent shim and, on a "secured-core" PC, allow the Microsoft
  3rd party UEFI CA in the firmware.
- **Not validated on real hardware.** Tested here: the files written by `build_img.sh` (shim, GRUB and kernel
  signed, SBAT, `MOK.cer`) and the signatures. Not tested: the boot under Secure Boot of the final image.

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
