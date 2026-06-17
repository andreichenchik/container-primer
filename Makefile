SWIFT := $(shell which swift)
DOCKER := $(shell which docker)

KATA_VERSION := 3.17.0
KATA_URL := https://github.com/kata-containers/kata-containers/releases/download/$(KATA_VERSION)/kata-static-$(KATA_VERSION)-arm64.tar.xz

BUILDX_BUILDER := primer-builder
IMAGE_TAG := container-primer:local
IMAGE_TAR := .local/image.tar
KERNEL := .local/vmlinux
SWIFT_SOURCE_INPUTS := $(shell find Sources -type d -o -type f)
SWIFT_PACKAGE_FILES := Package.swift Package.resolved ContainerPrimer.entitlements
IMAGE_INPUTS := $(shell find image -type d -o -type f)

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

# Build the container image as an OCI archive. Bootstraps a docker-container
# buildx builder (idempotent) because the OCI exporter is unsupported on
# Colima's default docker driver.
.local/image.tar: $(IMAGE_INPUTS)
	@mkdir -p .local
	$(DOCKER) buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 || \
		$(DOCKER) buildx create --name $(BUILDX_BUILDER) --driver docker-container
	$(DOCKER) buildx build --builder $(BUILDX_BUILDER) \
		--platform linux/arm64 \
		--provenance=false --sbom=false \
		-t $(IMAGE_TAG) \
		--output type=oci,dest=$(IMAGE_TAR) image

# Remove the built image, prepared rootfs, and the builder's cache.
clear-image: clear-rootfs
	rm -f $(IMAGE_TAR)
	$(DOCKER) buildx prune --all --force --builder $(BUILDX_BUILDER) 2>/dev/null || true

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
