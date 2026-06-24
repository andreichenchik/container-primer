# ContainerPrimer

A self-contained Swift binary that builds (or pulls) a container image and boots it in a lightweight
Linux VM, mounting a host `workspace/` read-only at `/workspace`. Built on Apple's
[Containerization](https://github.com/apple/containerization) framework.

The repo ships an example app under `example/`: a [pi](https://pi.dev) coding agent (Bun + Hono)
that answers questions about the mounted workspace.

![ContainerPrimer web UI: ask a question about the mounted workspace and a pi agent answers](preview.png)

## Install

```bash
brew install andreichenchik/tap/container-primer
container-primer run --build-image ./my-app ./my-workspace
```

Homebrew installs a prebuilt, signed binary (Apple silicon, macOS 26+) from the
[andreichenchik/homebrew-tap](https://github.com/andreichenchik/homebrew-tap) tap. The `make` /
`example/` workflow below is for local development from a checkout (Xcode 26+ / Swift 6.2+). See
`RELEASING.md` for cutting a release.

## How It Works

The binary is the whole product. It:

- **Builds** a local image from a `--build-image <context>` (driving Apple's `container` CLI), or
  **pulls** a `--image <ref>` from a registry (no container engine needed).
- Unpacks the image once into a cached **snapshot**, then clones that snapshot for each run
  so startup never re-unpacks.
- Auto-downloads and caches the Linux **kernel** on first run.
- Boots the VM, mounts `workspace/` read-only at `/workspace`, forwards every variable declared in
  `.env`, and runs the image's own `ENTRYPOINT`.

Editing the mounted workspace affects the next request without a rebuild; editing a build context
triggers a rebuild on the next run.

## Requirements

- Apple silicon Mac
- macOS 26+
- Apple's `container` CLI (`brew install container`) — only for `--build-image`

## Quick Start

```bash
cp .env.example .env   # then edit
make                   # builds example/image and runs it
```

| Variable          | Purpose           |
| ----------------- | ----------------- |
| `OPENAI_BASE_URL` | Endpoint base URL |
| `OPENAI_API_KEY`  | API key           |
| `OPENAI_MODEL`    | Model name        |

Open the printed URL and press Ctrl+C to stop the container.

`make` is shorthand for:

```bash
./.build/release/container-primer run --build-image example/image example/workspace
```

## Running other images

Build any context, or run any published image directly:

```bash
# Build a context (directory containing a Containerfile, or a Containerfile path)
./.build/release/container-primer run --build-image ./my-app ./my-workspace

# Pull a registry reference — no build, no container engine
./.build/release/container-primer run --image docker.io/library/nginx:latest example/workspace
make from-image IMAGE=docker.io/library/redis:latest    # convenience target
```

Reach the container at the printed IP (e.g. `curl http://<ip>/`). `--image` / `--build-image` also
work with the `prepare` subcommand (builds the snapshot without running).

## Commands

- `make`: build the binary and run the example.
- `make from-image`: run a registry reference (override with `IMAGE=`).
- `make prepare`: refresh the example's snapshot without running.
- `make debug`: build and run the debug binary.
- `make clean`: remove local build artifacts (`.build`).
- `make clean-cache`: remove the cached kernel and snapshots.

## Cache location

Generated artifacts live under `~/Library/Application Support/ContainerPrimer/`:

| Path               | Purpose                                  |
| ------------------ | ---------------------------------------- |
| `kernel/vmlinux`   | Linux kernel (auto-downloaded once)      |
| `snapshots/<key>/` | Cached rootfs + metadata, one per source |

## Troubleshooting

If startup misbehaves — e.g. a `vmnet` network error or a stale snapshot — it's usually leftover
state from an interrupted run. Reset with `make clean-cache` and run again. For `--build-image`,
make sure the container service is running (`container system start`).
