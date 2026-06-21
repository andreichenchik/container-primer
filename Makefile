SWIFT := $(shell which swift)

BIN_RELEASE := .build/release/container-primer
BIN_DEBUG := .build/debug/container-primer
ENTITLEMENTS := ContainerPrimer.entitlements

EXAMPLE_IMAGE := example/image
EXAMPLE_WORKSPACE := example/workspace
# Registry reference for `make from-image`; override on the command line.
IMAGE ?= docker.io/library/nginx:latest

REPO := andreichenchik/container-primer
TAP_REPO := andreichenchik/homebrew-tap
DIST := dist
TAP_DIR := $(DIST)/homebrew-tap
TAP_FORMULA := $(TAP_DIR)/Formula/container-primer.rb
TARBALL := container-primer-$(VERSION)-arm64-macos.tar.gz

.PHONY: all run from-image prepare debug build-release build-debug release clean clean-cache fmt

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

# Build, sign, package, and publish a release: uploads the signed binary here and
# bumps the formula in the homebrew-tap repo. Usage: make release VERSION=0.1.0
release:
	@test -n "$(VERSION)" || { echo "VERSION is required, e.g. make release VERSION=0.1.0"; exit 1; }
	$(MAKE) build-release
	mkdir -p $(DIST)
	tar -czf $(DIST)/$(TARBALL) -C $(dir $(BIN_RELEASE)) $(notdir $(BIN_RELEASE))
	gh release create v$(VERSION) $(DIST)/$(TARBALL) --repo $(REPO) --title "v$(VERSION)" --generate-notes \
	  || gh release upload v$(VERSION) $(DIST)/$(TARBALL) --repo $(REPO) --clobber
	rm -rf $(TAP_DIR) && gh repo clone $(TAP_REPO) $(TAP_DIR)
	@SHA=$$(shasum -a 256 $(DIST)/$(TARBALL) | awk '{print $$1}'); \
	  sed -i '' -E "s/^  version \".*\"/  version \"$(VERSION)\"/" $(TAP_FORMULA); \
	  sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$$SHA\"/" $(TAP_FORMULA); \
	  echo "Bumped tap formula: version $(VERSION), sha256 $$SHA"
	cd $(TAP_DIR) && git add Formula/container-primer.rb \
	  && git commit -m "container-primer $(VERSION)" && git push
	@echo "Released v$(VERSION). Install: brew install andreichenchik/tap/container-primer"

# Remove the cached kernel and rootfs snapshots from Application Support.
clean-cache: build-release
	$(BIN_RELEASE) clean

# Remove local build artifacts.
clean:
	$(SWIFT) package clean
	rm -rf .build

fmt:
	$(SWIFT) format --in-place --recursive Sources/ Tests/
