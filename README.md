# ContainerPrimer

An exploration of Apple's [Containerization](https://github.com/apple/containerization)
framework — learning how to boot lightweight Linux VMs and run containers from Swift on
Apple silicon.

It builds a local container image from `image/` (a `Dockerfile` based on `python:3-alpine`
that bakes in `image/server.py`), exports it to an OCI archive (`image.tar`), and loads that
archive into the image store instead of pulling from a registry. It then mounts the host
`workspace/` directory into the container over virtiofs at `/workspace`, and runs the baked-in
`/server.py` to serve that directory over HTTP. It prints a URL you can open from the host
(vmnet shared mode makes the container's IP reachable from macOS). The container keeps running
until you press Ctrl+C, then it is stopped and deleted — nothing is persisted. More to come as
the exploration continues.

Because `workspace/` is a live mount, editing `workspace/index.html` on the host changes what
the running container serves on the next request — no rebuild needed. Editing `image/server.py`
is different: it is baked into the image, so it needs an image rebuild (`make clear-image &&
make`), not just a restart.

## Requirements

- Mac with Apple silicon
- macOS 26+
- Xcode 26+ / Swift 6.2+
- A Docker CLI with `buildx`, backed by a Linux container runtime
  (e.g. [Colima](https://github.com/abiosoft/colima)) — used only to build `image.tar`

## Build & Run

Build the image, build the binary, codesign, and run:

```bash
make
```

`make` runs several steps: `swift build` (debug), `codesign` with the
`com.apple.security.virtualization` entitlement (required — the Virtualization API fails at
runtime without it), build the container image into `image.tar`, then run the binary. Run it
from the project root so the host `workspace/` directory and `image.tar` resolve.

The container image is built from `image/` (Dockerfile + `server.py`) via `docker buildx` and
exported as an OCI archive to `image.tar` (target: `make image.tar`). It is rebuilt only when
missing or when `image/Dockerfile` or `image/server.py` changes. The first build bootstraps a
dedicated `docker-container` buildx builder
(`primer-builder`), needed because the OCI exporter is unsupported on the default docker driver.
Use `make clear-image` to delete `image.tar` and prune the builder's cache.

The first build also fetches the Linux kernel into `./.vmlinux` (needs network); this is a
dependency of `make`/`make release` and is skipped once the file exists. Run it explicitly
with `make first-setup` if you prefer.

Use `make release` for the same steps with the release configuration. To build and codesign
without running (and without building the image), use `make build-debug` or `make build-release`.

Each run uses a unique container id (`primer-<uuid>`), so several instances can run in
parallel — each container gets its own IP, all serving on port 8080.

Expected output:

```
Starting container primer...
Fetching base container filesystem...
Loading image from /path/to/container-primer/image.tar...
Creating container from docker.io/library/container-primer:local...
Starting container...
Server running at http://192.168.64.2:8080
Press Ctrl+C to stop.
```

Open the printed URL (or `curl` it) to get the `workspace/index.html` page. Press Ctrl+C
to stop the server and tear the container down.

## Notes

- The kernel is fetched into `./.vmlinux` (gitignored) from the pinned
  [Kata Containers](https://github.com/kata-containers/kata-containers) release
  (`kata-static-3.17.0-arm64`).
- `image.tar` is an OCI image layout (gitignored) built locally rather than pulled from a
  registry; the app extracts it and loads it into the image store at startup.
