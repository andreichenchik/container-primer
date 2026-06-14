SWIFT := $(shell which swift)

.PHONY: all build-debug build-release release clean debug fmt first-setup

all: debug

build-release: .vmlinux
	$(SWIFT) build --configuration release
	codesign --force --sign - --entitlements container-primer.entitlements ./.build/release/container-primer

release: build-release
	./.build/release/container-primer

clean:
	$(SWIFT) package clean
	rm -rf ./build/debug
	rm -rf ./build/release

build-debug: .vmlinux
	$(SWIFT) build
	codesign --force --sign - --entitlements container-primer.entitlements ./.build/debug/container-primer

debug: build-debug
	./.build/debug/container-primer

fmt:
	$(SWIFT) format --in-place --recursive Sources/

first-setup: .vmlinux

.vmlinux:
	$(MAKE) -C ../containerization fetch-default-kernel
	cp -L ../containerization/.local/vmlinux ./.vmlinux
