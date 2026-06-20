SWIFT := $(shell which swift)

KATA_VERSION := 3.17.0
KATA_URL := https://github.com/kata-containers/kata-containers/releases/download/$(KATA_VERSION)/kata-static-$(KATA_VERSION)-arm64.tar.xz

BUILDX_BUILDER := primer-builder
IMAGE_TAG := container-primer:local
IMAGE_TAR := .local/image.tar
KERNEL := .local/vmlinux
SWIFT_SOURCE_INPUTS := $(shell find Sources -type d -o -type f)
SWIFT_PACKAGE_FILES := Package.swift Package.resolved ContainerPrimer.entitlements
IMAGE_INPUTS := $(shell find image -type d -o -type f)
export IMAGE_TAG IMAGE_TAR BUILDX_BUILDER

.PHONY: all build-debug build-release release clear clear-dist debug fmt first-setup prepare clear-image clear-rootfs

all: release

build-release: .build/release/ContainerPrimer

.build/release/ContainerPrimer: $(SWIFT_SOURCE_INPUTS) $(SWIFT_PACKAGE_FILES) $(KERNEL)
	$(SWIFT) build --configuration release
	codesign --force --sign - --entitlements ContainerPrimer.entitlements ./.build/release/ContainerPrimer

release: build-release $(IMAGE_TAR)
	./.build/release/ContainerPrimer prepare
	./.build/release/ContainerPrimer

clear: clear-dist clear-image
	rm -rf .build .local/benchmarks .local/opt .local/kata.tar.xz

clear-dist:
	$(SWIFT) package clean
	rm -rf ./build/debug
	rm -rf ./build/release

build-debug: .build/debug/ContainerPrimer

.build/debug/ContainerPrimer: $(SWIFT_SOURCE_INPUTS) $(SWIFT_PACKAGE_FILES) $(KERNEL)
	$(SWIFT) build
	codesign --force --sign - --entitlements ContainerPrimer.entitlements ./.build/debug/ContainerPrimer

debug: build-debug prepare
	./.build/debug/ContainerPrimer

prepare: build-release $(IMAGE_TAR)
	./.build/release/ContainerPrimer prepare

# Build the container image as an OCI archive. The script auto-selects a working
# container engine (prefers Podman, falls back to Docker).
.local/image.tar: $(IMAGE_INPUTS)
	scripts/build-image.sh build

# Remove the built image, prepared rootfs, and every engine's builder/cache.
clear-image: clear-rootfs
	rm -f $(IMAGE_TAR)
	scripts/build-image.sh clean

clear-rootfs:
	rm -f .local/rootfs.ext4 .local/rootfs.json .local/rootfs-*.ext4 .local/rootfs-*.json

fmt:
	$(SWIFT) format --in-place --recursive Sources/

first-setup: $(KERNEL)

$(KERNEL):
	@mkdir -p .local
	curl -SsL -o .local/kata.tar.xz $(KATA_URL)
	tar -xf .local/kata.tar.xz -C .local
	cp -L .local/opt/kata/share/kata-containers/vmlinux.container $(KERNEL)
