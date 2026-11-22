IMAGE?=archlinux-x86-64
# "default" = the builder of the Docker daemon: it sees the images loaded by the previous build
# (build-astroarch starts FROM the local base image). A docker-container builder, such as the one
# docker/setup-buildx-action creates in CI, does not, and would try to pull the base from Docker Hub.
BUILDER?=default
BOARD?=pc

# Build arguments to use a fork of astroarch:
#   make prepare-img ASTROARCH_REPO=https://github.com/<you>/astroarch.git ASTROARCH_BRANCH=<branch>
ASTROARCH_REPO?=https://github.com/devDucks/astroarch.git
ASTROARCH_BRANCH?=main
ASTROARCH_RAW?=https://raw.githubusercontent.com/devDucks/astroarch/refs/heads/$(ASTROARCH_BRANCH)

# --- Builds (native x86-64: no QEMU, no binfmt) ---
.PHONY: build-base
build-base:
	docker buildx build \
	  --builder $(BUILDER) \
	  --platform linux/amd64 \
	  -t $(IMAGE):latest \
	  -f dockerfiles/Dockerfile.base \
	  --target builder \
	  --load \
	  .

.PHONY: build-astroarch
build-astroarch: build-base
	docker buildx build \
	  --builder $(BUILDER) \
	  --build-arg BASE_IMAGE=$(IMAGE):latest \
	  --build-arg ASTROARCH_REPO=$(ASTROARCH_REPO) \
	  --build-arg ASTROARCH_BRANCH=$(ASTROARCH_BRANCH) \
	  --build-arg ASTROARCH_RAW=$(ASTROARCH_RAW) \
	  --platform linux/amd64 \
	  -t astroarch-x86-64:latest \
	  -f dockerfiles/Dockerfile.astroarch \
	  --target builder \
	  --load \
	  .

.PHONY: build-astroarch-rootfs
build-astroarch-rootfs: build-base
	docker buildx build \
	  --builder $(BUILDER) \
	  --build-arg BUILDKIT_SANDBOX_SIZE=30G \
	  --build-arg BASE_IMAGE=$(IMAGE):latest \
	  --build-arg ASTROARCH_REPO=$(ASTROARCH_REPO) \
	  --build-arg ASTROARCH_BRANCH=$(ASTROARCH_BRANCH) \
	  --build-arg ASTROARCH_RAW=$(ASTROARCH_RAW) \
	  --platform linux/amd64 \
	  -t astroarch-x86-64-rootfs:latest \
	  -f dockerfiles/Dockerfile.astroarch \
	  --target astroarch-rootfs \
	  --load \
	  .

.PHONY: create-rootfs-container
create-rootfs-container:
	docker create --platform=linux/amd64 --name take astroarch-x86-64-rootfs:latest sh

.PHONY: copy-rootfs-tar
copy-rootfs-tar:
	docker cp take:/astroarch-rootfs.tar ./rootfs.tar
	docker rm -f take

# Which packages of packages.txt / packages-x86.txt exist for x86_64 (official repos + astromatto)
#   make check-packages ASTROARCH_DIR=../astroarch
.PHONY: check-packages
check-packages:
	@[ -d "$(ASTROARCH_DIR)" ] || { echo "Usage: make check-packages ASTROARCH_DIR=<path of the astroarch repository>"; exit 1; }
	docker run --rm --platform linux/amd64 \
	  -v $(CURDIR)/scripts:/scripts:ro -v $(abspath $(ASTROARCH_DIR)):/astroarch:ro \
	  archlinux:latest bash /scripts/check-packages.sh /astroarch

# --- Bootable image (BIOS + UEFI) ---
# Board profiles live in boards/<name>.conf (ESP size, kernel console). Add one by dropping in a
# new .conf file - no Makefile changes needed.
.PHONY: check-board
check-board:
	@[ -f boards/$(BOARD).conf ] || { echo "Unknown BOARD=$(BOARD) (no boards/$(BOARD).conf)"; exit 1; }

.PHONY: prepare-img
prepare-img: check-board build-astroarch-rootfs create-rootfs-container copy-rootfs-tar
	BOARD=$(BOARD) IMG=archlinux-$(BOARD)-x86_64.img bash ./scripts/build_img.sh
