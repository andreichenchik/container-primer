SWIFT := $(shell which swift)

BIN_RELEASE := .build/release/ContainerPrimer
BIN_DEBUG := .build/debug/ContainerPrimer
ENTITLEMENTS := ContainerPrimer.entitlements

EXAMPLE_IMAGE := example/image
EXAMPLE_WORKSPACE := example/workspace
# Registry reference for `make from-image`; override on the command line.
IMAGE ?= docker.io/library/nginx:latest

.PHONY: all run from-image prepare debug build-release build-debug clean clean-cache fmt

all: run

# Build (with the virtualization entitlement) the binary must be signed at build
# time; it can't self-sign at runtime.
build-release:
	$(SWIFT) build --configuration release
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN_RELEASE)

build-debug:
	$(SWIFT) build
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN_DEBUG)

# Build the example image with podman/docker and run it.
run: build-release
	$(BIN_RELEASE) run --build-image $(EXAMPLE_IMAGE) $(EXAMPLE_WORKSPACE)

# Run a registry reference instead of building — no container engine needed.
from-image: build-release
	$(BIN_RELEASE) run --image $(IMAGE) $(EXAMPLE_WORKSPACE)

# Refresh the example's rootfs snapshot without running it.
prepare: build-release
	$(BIN_RELEASE) prepare --build-image $(EXAMPLE_IMAGE)

debug: build-debug
	$(BIN_DEBUG) run --build-image $(EXAMPLE_IMAGE) $(EXAMPLE_WORKSPACE)

# Remove the cached kernel and rootfs snapshots from Application Support.
clean-cache: build-release
	$(BIN_RELEASE) clean

# Remove local build artifacts.
clean:
	$(SWIFT) package clean
	rm -rf .build

fmt:
	$(SWIFT) format --in-place --recursive Sources/ Tests/
