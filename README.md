# container-primer

An exploration of Apple's [Containerization](https://github.com/apple/containerization)
framework — learning how to boot lightweight Linux VMs and run containers from Swift on
Apple silicon.

This first step is a SUUUUUPER simple smoke test: it boots an Alpine image, runs a single
`echo` command inside the container, prints the exit code, and exits. More to come as the
exploration continues.

## Requirements

- Mac with Apple silicon
- macOS 26+
- Xcode 26+ / Swift 6.2+
- A sibling checkout of [apple/containerization](https://github.com/apple/containerization)
  at `../containerization` (this package depends on it via a local path)

## Build & Run

Fetch the Linux kernel (one-time, needs network):

```bash
make fetch-default-kernel
```

Then build, codesign, and run:

```bash
make
```

`make` runs three steps: `swift build`, `codesign` with the
`com.apple.security.virtualization` entitlement (required — the Virtualization API fails at
runtime without it), then runs the binary.

Expected output:

```
Starting container primer...
Fetching base container filesystem...
Creating container from docker.io/library/alpine:3.16...
Starting container...
hello from container
Container exited with code 0
```

## Notes

- If you hit `vmnet_return_t(1001)` on first run, copy the binary to `/var/tmp` and run it there.
- The kernel is fetched into `./vmlinux` (gitignored) from the containerization repo's
  default kernel.
