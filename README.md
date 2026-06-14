# container-primer

An exploration of Apple's [Containerization](https://github.com/apple/containerization)
framework — learning how to boot lightweight Linux VMs and run containers from Swift on
Apple silicon.

It boots a `python:3-alpine` image, mounts the host `src/` directory into the container
over virtiofs, and runs `src/server.py` to serve `src/public/` over HTTP. It prints a URL
you can open from the host (vmnet shared mode makes the container's IP reachable from
macOS). The container keeps running until you press Ctrl+C, then it is stopped and deleted
— nothing is persisted. More to come as the exploration continues.

Because `src/` is a live mount, editing `src/public/index.html` on the host changes what
the running container serves on the next request — no rebuild needed. Editing `server.py`
itself needs a restart (Ctrl+C, then re-run), since the Python process is already running.

## Requirements

- Mac with Apple silicon
- macOS 26+
- Xcode 26+ / Swift 6.2+
- A sibling checkout of [apple/containerization](https://github.com/apple/containerization)
  at `../containerization` (this package depends on it via a local path)

## Build & Run

Build, codesign, and run:

```bash
make
```

`make` runs three steps: `swift build` (debug), `codesign` with the
`com.apple.security.virtualization` entitlement (required — the Virtualization API fails at
runtime without it), then runs the binary. Run it from the project root so the host `src/`
directory resolves.

The first build also fetches the Linux kernel into `./.vmlinux` (needs network); this is a
dependency of `make`/`make release` and is skipped once the file exists. Run it explicitly
with `make first-setup` if you prefer.

Use `make release` for the same steps with the release configuration. To build and codesign
without running, use `make build-debug` or `make build-release`.

Each run uses a unique container id (`primer-<uuid>`), so several instances can run in
parallel — each container gets its own IP, all serving on port 8080.

Expected output:

```
Starting container primer...
Fetching base container filesystem...
Creating container from docker.io/library/python:3-alpine...
Starting container...
Server running at http://192.168.64.2:8080
Press Ctrl+C to stop.
```

Open the printed URL (or `curl` it) to get the `src/public/index.html` page. Press Ctrl+C
to stop the server and tear the container down.

## Notes

- If you hit `vmnet_return_t(1001)` on first run, copy `./.build/debug/container-primer` to
  `/var/tmp` and run it there, passing the absolute path to `src/`, e.g.
  `./container-primer /Users/you/.../container-primer/src`.
- The kernel is fetched into `./.vmlinux` (gitignored) from the containerization repo's
  default kernel.
