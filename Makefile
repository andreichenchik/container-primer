SWIFT := $(shell which swift)

KATA_VERSION := 3.17.0
KATA_URL := https://github.com/kata-containers/kata-containers/releases/download/$(KATA_VERSION)/kata-static-$(KATA_VERSION)-arm64.tar.xz

.PHONY: all build-debug build-release release clean debug fmt first-setup

all: debug

build-release: .vmlinux
	$(SWIFT) build --configuration release
	codesign --force --sign - --entitlements ContainerPrimer.entitlements ./.build/release/ContainerPrimer

release: build-release
	./.build/release/ContainerPrimer

clean:
	$(SWIFT) package clean
	rm -rf ./build/debug
	rm -rf ./build/release

build-debug: .vmlinux
	$(SWIFT) build
	codesign --force --sign - --entitlements ContainerPrimer.entitlements ./.build/debug/ContainerPrimer

debug: build-debug
	./.build/debug/ContainerPrimer

fmt:
	$(SWIFT) format --in-place --recursive Sources/

first-setup: .vmlinux

.vmlinux:
	@mkdir -p .local
	curl -SsL -o .local/kata.tar.xz $(KATA_URL)
	tar -xf .local/kata.tar.xz -C .local
	cp -L .local/opt/kata/share/kata-containers/vmlinux.container ./.vmlinux
