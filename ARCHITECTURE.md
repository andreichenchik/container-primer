# Architecture

ContainerPrimer is a thin Swift launcher around Apple's
[Containerization](https://github.com/apple/containerization) framework. It boots a lightweight
Linux VM, mounts the host `workspace/` read-only, and runs a containerized web app (a Bun + Hono
server hosting a [pi](https://pi.dev) coding agent). The Swift side never knows about the agent — it
only prepares a root filesystem and runs whatever the image's `ENTRYPOINT` defines.

The system has two halves:

1. **Host launcher** — a Swift CLI (`Sources/ContainerPrimer/`) that turns a container image into a
   cached ext4 rootfs and boots a VM from it.
2. **Container image** — a TypeScript app (`image/`) baked into an OCI image that serves the web UI
   and answers questions about `/workspace`.

```
┌─ host (macOS) ────────────────────────────────────────────┐
│  ContainerPrimer CLI                                       │
│    prepare → cached .local/rootfs.ext4 (+ rootfs.json)     │
│    run     → clone rootfs → boot VM via Containerization   │
│                                  │                         │
│   workspace/  ──virtiofs (ro)──► │                         │
└──────────────────────────────────┼────────────────────────┘
                                    ▼
                      ┌─ Linux VM (guest) ──────────────┐
                      │  Bun + Hono server (server.ts)  │
                      │    GET /     → web UI           │
                      │    POST /ask → pi agent reads   │
                      │                /workspace       │
                      └─────────────────────────────────┘
```

## High-level flow

### Build (`make`)
1. `scripts/build-image.sh build` builds `image/Containerfile` into `.local/image.tar` (an OCI
   archive). It auto-selects a container engine — prefers Podman, falls back to Docker buildx.
2. The Swift package builds to `.build/release/ContainerPrimer` and is code-signed with the
   `com.apple.security.virtualization` entitlement (required to start a VM).
3. The kernel `.local/vmlinux` is fetched once from a Kata Containers release (`make first-setup`,
   pulled in transitively as a build prerequisite).

### Prepare (`ContainerPrimer prepare`)
Unpacks the image into `.local/rootfs.ext4`, a cached Linux filesystem, and records what it was
built from in `.local/rootfs.json`. Skipped when the cache already matches the current image.

### Run (`ContainerPrimer run`)
Clones the cached rootfs (cheap APFS copy-on-write), boots a VM, mounts `workspace/` read-only,
forwards `.env` variables, and runs the image entrypoint until the server exits or Ctrl+C.

Editing `workspace/` affects the next request immediately (it's a live mount). Editing `image/`
requires `make clear-image && make` to rebuild and re-prepare.

## Host launcher (`Sources/ContainerPrimer/`)

Swift 6.2 executable. Depends on `Containerization`, `ContainerizationOS`, `ContainerizationArchive`
(Apple), and `ArgumentParser`.

### Entry point — `ContainerPrimer.swift`
`@main` `AsyncParsableCommand` with two subcommands; `run` is the default.

- **`Run`** — args: optional `workspacePath`, optional `--image <ref>`. When `--image` is given it
  prepares a rootfs on demand from a registry pull (no local build or engine needed), then calls
  `ContainerRunner().run(...)`.
- **`Prepare`** — `--force` rebuilds even if current; `--image <ref>` selects a `RegistryImageSource`,
  otherwise an `ArchiveImageSource` over `.local/image.tar`. Delegates to `RootfsPreparer`.

### Image acquisition — `ImageSource.swift`
`ImageSource` protocol abstracts where the image comes from, so prepare logic is identical for both:

```swift
protocol ImageSource {
  func resolve(in store: ImageStore) async throws -> Image
  func isCacheValid(_ metadata: RootfsMetadata) throws -> Bool
  func archiveFingerprint() throws -> ImageArchiveFingerprint?
}
```

- **`ArchiveImageSource`** — extracts `.local/image.tar` (via `ArchiveReader`) into a temp dir and
  `store.load`s it. Cache validity is keyed on the archive's size + mtime fingerprint.
- **`RegistryImageSource`** — `store.get(reference:pull:true)`. Cache validity is keyed on the
  reference string; has no archive fingerprint (`nil`).

### Rootfs preparation — `RootfsPreparer.swift`
`prepare(source:force:)`:
1. Ensures `.local/`, sweeps temp files from any interrupted prepare.
2. Fast path: if not `force`, metadata loads, the cached rootfs exists, the source says the cache is
   valid, and the image still resolves to the recorded digest → returns early.
3. Otherwise resolves the image and unpacks it with `EXT4Unpacker(blockSizeInBytes: 1.gib())` into a
   temp `rootfs-<uuid>.ext4`.
4. Writes a temp `RootfsMetadata`, then atomically moves both temp files onto
   `.local/rootfs.ext4` and `.local/rootfs.json` (so a crash never leaves a half-written cache).

### Cache metadata — `RootfsMetadata.swift`
- **`RootfsMetadata`** — `imageReference`, `imageDigest`, optional `imageArchive` fingerprint
  (`nil` for registry pulls), `rootfsSizeInBytes`, `createdAt`. JSON, ISO-8601 dates. Persisted as
  `.local/rootfs.json`.
- **`ImageArchiveFingerprint`** — `{ sizeInBytes, modificationTimeSince1970 }` of the OCI archive.
  Used to detect a rootfs that's stale relative to `.local/image.tar`.

### Booting the VM — `ContainerRunner.swift`
`run(workspacePath:)` is the core:
1. `DotEnv.load()` reads `.env` and returns the declared keys (the forwarding contract).
2. `loadPreparedRootfsMetadata()` validates the cache: rootfs + metadata exist, and for
   archive-sourced rootfs the current archive fingerprint still matches (registry rootfs skip this).
3. Builds a `ContainerManager` with `Kernel(.local/vmlinux, .linuxArm)`, the pinned vminit base
   filesystem (`ghcr.io/apple/containerization/vminit:0.26.5`), and a `VmnetNetwork`.
4. Resolves the prepared image from the manager's `imageStore` and asserts its digest still equals
   the recorded one.
5. Clones the cached rootfs to a per-run `rootfs.ext4` under the image store
   (`RootfsFileSystem.cloneRootfs`, APFS clone with copy fallback). The container ID is
   `primer-<uuid>` so multiple instances run in parallel.
6. `manager.create` with a config closure: 2 CPUs, 512 MiB, `workspace/` shared read-only at
   `/workspace` over virtiofs, stdout/stderr piped to the host via `HostWriter`, and each `.env`
   key forwarded as an env var (the shell environment wins over `.env` values). The command,
   working dir, and base env all come from the image (`ENTRYPOINT`/`WORKDIR`/`ENV`).
7. `create()` + `start()`, prints the container IPv4, then waits in a task group: one task watches
   `SIGINT`/`SIGTERM` and stops the container; the main path awaits `container.wait()`. A `defer`
   deletes the container so nothing persists.

### Supporting types
- **`DotEnv.swift`** — parses `KEY=VALUE` (skips comments/blanks, drops `export `, trims, strips
  matching quotes); `load` calls `setenv(key, value, 0)` (the `0` overwrite flag is what lets the
  shell environment take precedence) and returns the keys it declared.
- **`HostWriter.swift`** — `Writer` adapter that forwards container process output to a host
  `FileHandle` so guest logs appear on the host terminal.
- **`ProjectPaths.swift`** — central definition of `.local/` paths (`imageTar`, `kernel`,
  `cachedRootfs`, `metadata`) and the per-run container directory under the image store.
- **`RootfsFileSystem.swift`** — `clonefile`-based COW clone (copy fallback), atomic
  `replaceItem`, and cleanup of leftover `rootfs-*` temp files.

## Container image (`image/`)

OCI image built from `image/Containerfile`. Multi-stage Bun build: a cached `install` stage runs
`bun install --frozen-lockfile --production`; the `release` stage copies prod `node_modules` plus
`server.ts`, `index.html`, `package.json`. `ENTRYPOINT ["bun", "run", "server.ts"]`, exposes 8080.

### `server.ts` (Bun + Hono)
- Reads `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL` from env (forwarded from the host
  `.env`); exits if any is missing.
- Registers an in-memory OpenAI-compatible provider/model via `@earendil-works/pi-coding-agent`
  (`AuthStorage.inMemory`, `ModelRegistry.inMemory`) — nothing is read from or written to `~/.pi`.
- Routes:
  - `GET /` → serves `index.html`.
  - `POST /ask` → body is the question; `ask()` opens a fresh agent session
    (`createAgentSession`) rooted at `/workspace` with read-only tools (`read`, `grep`, `find`,
    `ls`), runs the prompt, and returns the assistant text. Agent events are logged to stderr;
    errors surface as HTTP 500.
- `index.html` is a minimal form that POSTs the question to `/ask` and shows the answer.

The agent only reads the mounted workspace, and the mount is read-only, so a request can't modify
host files.

## Tests (`Tests/ContainerPrimerTests/`)

Swift Testing (`@Suite`/`@Test`) over the pure host logic:
- `DotEnvTests` — parsing edge cases (comments, `export`, quotes, whitespace, malformed lines).
- `ImageArchiveFingerprintTests` — fingerprint reflects size and changes on rewrite.
- `ImageSourceTests` — cache-validity rules for registry vs archive sources.
- `RootfsMetadataTests` — JSON round-trip with and without an archive fingerprint.

VM boot, image building, and unpacking are not unit-tested (they need an engine, the kernel, and the
virtualization entitlement); they're exercised by running the binary.

## Generated artifacts (`.local/`, gitignored)

| File             | Produced by            | Purpose                                  |
| ---------------- | ---------------------- | ---------------------------------------- |
| `image.tar`      | `build-image.sh`       | OCI archive of the built image           |
| `rootfs.ext4`    | `ContainerPrimer prepare` | Cached Linux filesystem to clone per run |
| `rootfs.json`    | `ContainerPrimer prepare` | Cache metadata (image ref/digest/fingerprint) |
| `vmlinux`        | `make first-setup`     | Linux kernel (from Kata Containers)      |
