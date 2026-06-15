# ContainerPrimer

An exploration of Apple's [Containerization](https://github.com/apple/containerization)
framework — booting lightweight Linux VMs and running containers from Swift on Apple silicon.

![ContainerPrimer web UI: ask a question about the mounted workspace and a pi agent answers](preview.png)

It serves a web page with a question box. On submit, a fresh [pi](https://pi.dev) coding-agent
session reads the mounted `workspace/` and answers your question.

## How it works

- Builds a container image from `image/` (a `node:22-slim` Dockerfile baking in the TypeScript
  app `image/server.ts`) and exports it to an OCI archive, `image.tar`.
- Loads `image.tar` into the local image store instead of pulling from a registry.
- Mounts the host `workspace/` into the container over virtiofs at `/workspace`.
- Runs the baked-in app, which serves the question page and spawns a pi agent (OpenAI-compatible
  endpoint, configured via env vars) that can read `/workspace`.
- Prints a URL reachable from macOS (vmnet shared mode). Ctrl+C stops and deletes the container —
  nothing is persisted.

Editing files under `workspace/` changes what the agent reads on the next request — no rebuild.
Editing `image/server.ts` or `image/package.json` is baked into the image, so it needs a rebuild
(`make clear-image && make`).

## Requirements

- Mac with Apple silicon
- macOS 26+
- Xcode 26+ / Swift 6.2+
- A Docker CLI with `buildx`, backed by a Linux runtime (e.g.
  [Colima](https://github.com/abiosoft/colima)) — used only to build `image.tar`

## Quick start

The agent needs an OpenAI-compatible endpoint. The launcher loads a `.env` file from the project
root on startup, so the simplest setup is:

```bash
cp .env.example .env   # then edit
make
```

| Variable          | Purpose                          |
| ----------------- | -------------------------------- |
| `OPENAI_BASE_URL` | Endpoint base URL                |
| `OPENAI_API_KEY`  | API key                          |
| `OPENAI_MODEL`    | Model name                       |

Shell environment variables take precedence over `.env`, so you can pass them inline instead:

```bash
OPENAI_BASE_URL=https://api.openai.com/v1 OPENAI_API_KEY=sk-... OPENAI_MODEL=gpt-4o-mini make
```

Run `make` from the project root so `workspace/` and `image.tar` resolve. Open the printed URL,
ask a question (e.g. "What files are in the workspace?"), and the answer appears below. Press
Ctrl+C to tear down.

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

## Build details

`make` runs: `swift build` (debug), `codesign` with the `com.apple.security.virtualization`
entitlement (required — the Virtualization API fails at runtime without it), build `image.tar`,
then run the binary.

| Target               | What it does                                          |
| -------------------- | ----------------------------------------------------- |
| `make`               | Build, codesign, build image, run (debug)             |
| `make release`       | Same, release configuration                           |
| `make build-debug`   | Build + codesign only, no image, no run               |
| `make build-release` | Build + codesign only, release configuration          |
| `make image.tar`     | Build the container image                             |
| `make clear-image`   | Delete `image.tar` and prune the builder cache        |
| `make first-setup`   | Fetch the Linux kernel into `./.vmlinux`              |

- The image is rebuilt only when missing or when a file under `image/` changes. The build runs
  `npm install`, so it needs network. The first build bootstraps a dedicated `docker-container`
  buildx builder (`primer-builder`), needed because the OCI exporter is unsupported on the default
  docker driver.
- The first build also fetches the Linux kernel into `./.vmlinux` (needs network), skipped once
  the file exists.
- Each run uses a unique container id (`primer-<uuid>`), so several instances can run in
  parallel — each gets its own IP, all serving on port 8080.

## Notes

- The kernel is fetched into `./.vmlinux` (gitignored) from the pinned
  [Kata Containers](https://github.com/kata-containers/kata-containers) release
  (`kata-static-3.17.0-arm64`).
- `image.tar` is an OCI image layout (gitignored) built locally rather than pulled from a
  registry; the app extracts it and loads it into the image store at startup.
