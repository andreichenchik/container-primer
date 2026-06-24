# agent-wrap

A thin wrapper that runs a **containerized agent** inside a lightweight, sandboxed macOS VM — no
Docker, no daemon. Point it at an agent image (pulled from a registry or built from a `Containerfile`)
and it boots the agent in a fresh Linux VM, mounting a host `workspace/` so the agent can work on your
files without touching the rest of your machine.

Built on Apple's [Containerization](https://github.com/apple/containerization) framework. Pulling a
published image needs no container engine at all.

![agent-wrap web UI: ask a question about the mounted workspace and the agent answers](preview.png)

## Install

```bash
brew install andreichenchik/tap/agent-wrap
```

Homebrew installs a prebuilt, signed binary (Apple silicon, macOS 26+) from the
[andreichenchik/homebrew-tap](https://github.com/andreichenchik/homebrew-tap) tap.

> **Upgrading from `container-primer`?** It was renamed to `agent-wrap`. Run `brew update && brew
> upgrade` and Homebrew migrates you automatically. The old cache under
> `~/Library/Application Support/ContainerPrimer` is no longer used and is safe to delete — the new
> binary regenerates its kernel and snapshots on first run.

## Run an agent

Pull a published image and run it — no container engine required:

```bash
agent-wrap run --image ghcr.io/you/your-agent:latest ./workspace
```

`./workspace` is mounted **read-only** at `/workspace` inside the VM, so the agent can read your
files but can't change them. When the agent listens on a port, its URL is printed on your terminal:

```
[port-listener] listening on http://<ip>:<port>
```

Open it, interact with the agent, and press Ctrl+C to stop.

### Build your own agent

Point `--build-image` at a directory with a `Containerfile`/`Dockerfile` (or at the file itself).
This path builds with Apple's `container` CLI, so it needs the container service running:

```bash
agent-wrap run --build-image ./my-agent ./workspace
```

Editing the mounted `workspace/` affects the next request with no rebuild. Editing the build context
triggers a rebuild on the next run.

## Interactive shell and custom commands

Pass a command after `--` to run it instead of the image's entrypoint, and add `-i` to attach your
terminal (raw mode, live resize, Ctrl+C forwarded to the guest):

```bash
# Drop into a shell inside the agent image (defaults to /bin/sh)
agent-wrap run --build-image ./my-agent -i

# Run an explicit command interactively
agent-wrap run --image ghcr.io/you/your-agent:latest -i -- /bin/bash

# One-off command, output streamed to the host
agent-wrap run --image docker.io/library/alpine:latest -- ls -la /
```

Interactive sessions start in `/workspace`. It is read-only by default; add `-w`/`--write` to let the
agent modify host files from inside the VM.

## Configuration (`.env`)

Every variable declared in a `.env` file in the current directory is forwarded into the VM (the host
shell wins on conflicts). The included example agent reads:

| Variable          | Purpose           |
| ----------------- | ----------------- |
| `OPENAI_BASE_URL` | Endpoint base URL |
| `OPENAI_API_KEY`  | API key           |
| `OPENAI_MODEL`    | Model name        |

## Rootfs size

The rootfs has 8 GiB of usable capacity by default. Override it with `--disk-size <GiB>` on `run` or
`prepare` (e.g. when an install step runs out of space):

```bash
agent-wrap run --image docker.io/library/node:22-slim ./workspace -i --disk-size 16 -- bash
```

Changing the size rebuilds the snapshot on the next run. The backing file is sparse, so unused space
costs nothing on the host.

## Commands

- `run` — prepare (if needed) and boot the agent. The default subcommand.
- `prepare` — build the cached rootfs snapshot without running (`--force` to rebuild).
- `clean` — remove the cached kernel and all rootfs snapshots.

Run `agent-wrap help <command>` for full options.

## Cache location

Generated artifacts live under `~/Library/Application Support/AgentWrap/`:

| Path               | Purpose                                  |
| ------------------ | ---------------------------------------- |
| `kernel/vmlinux`   | Linux kernel (auto-downloaded once)      |
| `snapshots/<key>/` | Cached rootfs + metadata, one per source |

## Requirements

- Apple silicon Mac
- macOS 26+
- Apple's `container` CLI (`brew install container`) — only for `--build-image`

## Troubleshooting

If startup misbehaves — e.g. a `vmnet` network error or a stale snapshot — it's usually leftover
state from an interrupted run. Reset with `agent-wrap clean` and run again. For `--build-image`, make
sure the container service is running (`container system start`).

## Included example agent

The repo ships an example under `example/`: a [pi](https://pi.dev) coding agent (Bun + Hono) that
answers questions about the mounted workspace, with read-only tools (`read`, `grep`, `find`, `ls`).
From a checkout (Xcode 26+ / Swift 6.2+):

```bash
cp .env.example .env   # then edit
make                   # builds example/image and runs it
```

`make` is shorthand for:

```bash
./.build/release/agent-wrap run --build-image example/image example/workspace
```

See `ARCHITECTURE.md` for how it works and `RELEASING.md` for cutting a release.
