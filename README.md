# container-primer

An exploration of Apple's [Containerization](https://github.com/apple/containerization)
framework — learning how to boot lightweight Linux VMs and run containers from Swift on
Apple silicon.

It boots a `python:3-alpine` image, starts a tiny HTTP server inside the container, and
prints a URL you can open from the host (vmnet shared mode makes the container's IP
reachable from macOS). The container keeps running until you press Ctrl+C, then it is
stopped and deleted — nothing is persisted. More to come as the exploration continues.

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

For a faster iteration loop, `make run-debug` does the same (build, sign, run) using the
debug configuration.

Expected output:

```
Starting container primer...
Fetching base container filesystem...
Creating container from docker.io/library/python:3-alpine...
Starting container...
Server running at http://192.168.64.2:8080
Press Ctrl+C to stop.
```

Open the printed URL (or `curl` it) to get `hello from container`. Press Ctrl+C to stop
the server and tear the container down.

## Notes

- If you hit `vmnet_return_t(1001)` on first run, copy the binary to `/var/tmp` and run it there.
- The kernel is fetched into `./vmlinux` (gitignored) from the containerization repo's
  default kernel.
