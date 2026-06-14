SWIFT := $(shell which swift)
DOCKER := $(shell which docker)

KATA_VERSION := 3.17.0
KATA_URL := https://github.com/kata-containers/kata-containers/releases/download/$(KATA_VERSION)/kata-static-$(KATA_VERSION)-arm64.tar.xz

BUILDX_BUILDER := primer-builder
IMAGE_TAG := container-primer:local

.PHONY: all build-debug build-release release clean debug fmt first-setup clear-image

all: debug

build-release: .vmlinux
	$(SWIFT) build --configuration release
	codesign --force --sign - --entitlements ContainerPrimer.entitlements ./.build/release/ContainerPrimer

release: build-release image.tar
	./.build/release/ContainerPrimer

clean:
	$(SWIFT) package clean
	rm -rf ./build/debug
	rm -rf ./build/release

build-debug: .vmlinux
	$(SWIFT) build
	codesign --force --sign - --entitlements ContainerPrimer.entitlements ./.build/debug/ContainerPrimer

debug: build-debug image.tar
	./.build/debug/ContainerPrimer

# Build the container image as an OCI archive. Rebuilds only when missing or the
# Dockerfile changed. Bootstraps a docker-container buildx builder (idempotent)
# because the OCI exporter is unsupported on Colima's default docker driver.
image.tar: $(shell find image -type f)
	$(DOCKER) buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 || \
		$(DOCKER) buildx create --name $(BUILDX_BUILDER) --driver docker-container
	$(DOCKER) buildx build --builder $(BUILDX_BUILDER) \
		--platform linux/arm64 \
		--provenance=false --sbom=false \
		-t $(IMAGE_TAG) \
		--output type=oci,dest=image.tar image

# Remove the built image and the builder's cache.
clear-image:
	rm -f image.tar
	$(DOCKER) buildx prune --all --force --builder $(BUILDX_BUILDER) 2>/dev/null || true

fmt:
	$(SWIFT) format --in-place --recursive Sources/

first-setup: .vmlinux

.vmlinux:
	@mkdir -p .local
	curl -SsL -o .local/kata.tar.xz $(KATA_URL)
	tar -xf .local/kata.tar.xz -C .local
	cp -L .local/opt/kata/share/kata-containers/vmlinux.container ./.vmlinux
