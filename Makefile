SWIFT := $(shell which swift)

.PHONY: all build clean run debug run-debug fmt fetch-default-kernel

all: run

build:
	$(SWIFT) build --configuration release
	codesign --force --sign - --entitlements container-primer.entitlements ./.build/release/container-primer
	cp ./.build/release/container-primer ./container-primer

clean:
	$(SWIFT) package clean
	rm -f ./container-primer

run: build
	./container-primer

debug:
	$(SWIFT) build
	codesign --force --sign - --entitlements container-primer.entitlements ./.build/debug/container-primer

run-debug: debug
	./.build/debug/container-primer

fmt:
	$(SWIFT) format --in-place --recursive Sources/

fetch-default-kernel:
	$(MAKE) -C ../containerization fetch-default-kernel
	cp -L ../containerization/.local/vmlinux ./vmlinux
