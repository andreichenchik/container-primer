# Architecture

ContainerPrimer is a self-contained Swift binary built on Apple's
[Containerization](https://github.com/apple/containerization) framework. It builds or pulls a
container image, caches a Linux root filesystem snapshot from it, and boots a lightweight VM that
mounts the host `workspace/` read-only and runs the image's own `ENTRYPOINT`. The Swift side never
knows about the workload — it only prepares a rootfs and runs whatever the image defines.

Everything that used to be shell glue (image building, kernel download) now lives in the binary, so
the binary is the entire product. Image building shells out to Apple's `container` CLI, driven from
Swift instead of bash.

```
┌─ host (macOS) ─────────────────────────────────────────────┐
│  ContainerPrimer binary                                     │
│    image source ──► OCI image (in framework store)          │
│      --build-image: container build → temp OCI tar          │
│      --image:       registry pull                           │
│    prepare → unpack image → cached snapshot (rootfs.ext4)   │
│    run     → clone snapshot → boot VM via Containerization  │
│                                  │                          │
│   workspace/  ──virtiofs (ro)──► │                          │
└──────────────────────────────────┼─────────────────────────┘
                                    ▼
                      ┌─ Linux VM (guest) ──────────────┐
                      │  the image's ENTRYPOINT          │
                      │  (example: Bun + Hono pi agent)  │
                      └─────────────────────────────────┘
```

## High-level flow

### Image source (`--build-image` or `--image`)
A run/prepare requires exactly one source:
- `--build-image <context>` — a directory (with a `Containerfile`/`Dockerfile`) or a Containerfile
  path. Built with Apple's `container` CLI into a **temporary** OCI archive, which is loaded into the
  framework's image store and then deleted. Only the snapshot and the loaded OCI image persist.
- `--image <ref>` — pulled from a registry into the image store. No container engine required.

### Prepare
Resolves the source to an OCI image, unpacks it once into a cached ext4 snapshot, and records what
it was built from. Skipped when a snapshot for the same source already exists.

### Run
Ensures the kernel exists (auto-downloads on first use), ensures a current snapshot exists (calls
prepare), clones the snapshot (cheap APFS copy-on-write), boots a VM, mounts `workspace/` read-only
at `/workspace`, forwards `.env` variables, and runs the image entrypoint until it exits or Ctrl+C.

Editing the mounted workspace affects the next request immediately (live mount). Editing a build
context changes its cache key, so the next run rebuilds and re-prepares automatically.

## Storage

| Location                                                 | Holds                                   |
| -------------------------------------------------------- | --------------------------------------- |
| `~/Library/Application Support/ContainerPrimer/kernel/`  | `vmlinux`, auto-downloaded once         |
| `~/Library/Application Support/ContainerPrimer/snapshots/<key>/` | `rootfs.ext4` + `rootfs.json` per source |
| `~/Library/Application Support/com.apple.containerization` | OCI images (framework's own store)    |

`<key>` is a SHA-256 derived from the source: the reference string for a registry pull, or a
fingerprint (path + size + mtime of every context file plus the Containerfile) for a build. Distinct
sources therefore get distinct snapshots, and an unchanged build context skips the engine entirely.
The intermediate build archive (`image → tar → snapshot`) is temporary and never kept.

## Host binary (`Sources/ContainerPrimer/`)

Swift 6.2 executable. Depends on `Containerization`, `ContainerizationOS`, `ContainerizationArchive`
(Apple), `ArgumentParser`, and `CryptoKit` (system, for cache-key hashing).

### Entry point — `ContainerPrimer.swift`
`@main` `AsyncParsableCommand` with `run` (default), `prepare`, and `clean`. `SourceOptions` is a
shared `ParsableArguments` group exposing `--image` / `--build-image`; `makeSource()` validates that
exactly one is given and resolves `--build-image` into a context dir + Containerfile.

### Image acquisition — `ImageSource.swift`
`ImageSource` abstracts where the image comes from:

```swift
protocol ImageSource {
  func resolve(in store: ImageStore) async throws -> Image
  var cacheKey: String { get throws }
}
```

A default `isCacheValid(_:)` compares `metadata.cacheKey` to the source's `cacheKey`.
- **`BuildImageSource`** — builds via `ContainerEngine`, extracts the temp OCI tar (`ArchiveReader`),
  `store.load`s it, deletes the tar; `cacheKey` is the context fingerprint.
- **`RegistryImageSource`** — `store.get(reference:pull:true)`; `cacheKey` is a hash of the reference.

### Image building — `ContainerEngine.swift`
Drives Apple's `container` CLI. `ensureAvailable()` probes `container system status` and, if the
service isn't running, throws guidance to start it (it never starts the service itself).
`build(contextDir:containerfile:tag:)` runs `container build --output type=tar,dest=…` to write a
temporary OCI-archive tar and returns its URL for the caller to load and delete.

### Kernel — `KernelProvider.swift`
`ensureKernel()` returns the cached `vmlinux`, downloading the pinned Kata Containers static tarball
and copying out its real `vmlinux-<kver>` kernel on first use. Replaces the old Makefile `curl` step.

### Cache keys — `CacheKey.swift`
`hashing(_:)` is SHA-256 hex of a string; `forContext(dir:containerfile:)` builds the build-context
fingerprint without reading file contents.

### Rootfs preparation — `RootfsPreparer.swift`
`prepare(source:force:)` resolves the snapshot slot from the source's `cacheKey`, returns early when
a valid snapshot exists, otherwise resolves the image, unpacks with
`EXT4Unpacker(blockSizeInBytes: 1.gib())` into temp files under the snapshot dir, and atomically
moves them into place (so a crash never leaves a half-written cache).

### Cache layout — `CacheStore.swift` / `ProjectPaths.swift`
`CacheStore` resolves the Application Support base and exposes `kernel` and `snapshot(forKey:)`.
`ProjectPaths` only holds cwd-relative inputs (the default `workspace/`).

### Cache metadata — `RootfsMetadata.swift`
`{ cacheKey, imageReference, imageDigest, rootfsSizeInBytes, createdAt }`, JSON with ISO-8601 dates,
persisted as `snapshots/<key>/rootfs.json`.

### Booting the VM — `ContainerRunner.swift`
`run(source:workspacePath:)`:
1. `DotEnv.load()` reads `.env` and returns the keys to forward.
2. Locates the snapshot from the source's `cacheKey` and validates rootfs + metadata exist.
3. `KernelProvider.ensureKernel()` for the kernel.
4. Builds a `ContainerManager` with the kernel, the pinned vminit base
   (`ghcr.io/apple/containerization/vminit:0.26.5`), and a `VmnetNetwork`.
5. Resolves the prepared image from the store and asserts its digest matches the recorded one.
6. Clones the snapshot to a per-run `rootfs.ext4` under the image store (`RootfsFileSystem`), with a
   `primer-<uuid>` container ID so instances run in parallel.
7. `manager.create` with 2 CPUs, 512 MiB, `workspace/` shared read-only over virtiofs, stdout/stderr
   piped to the host (`HostWriter`), and each `.env` key forwarded (shell wins). Command, working
   dir, and base env come from the image config.
8. `create()` + `start()`, prints the container IPv4, then waits: one task watches `SIGINT`/`SIGTERM`
   and stops the container; the main path awaits `container.wait()`. A `defer` deletes the container.

### Supporting types
- **`DotEnv.swift`** — parses `KEY=VALUE` (skips comments/blanks, drops `export `, trims, strips
  matching quotes); `load` uses `setenv(key, value, 0)` so the shell environment takes precedence.
- **`HostWriter.swift`** — forwards container process output to a host `FileHandle`.
- **`RootfsFileSystem.swift`** — `clonefile`-based COW clone (copy fallback), atomic replace, and
  cleanup of leftover `rootfs-*` temp files.

## Example workload (`example/`)

`example/image` is an OCI build context, `example/workspace` is the mounted directory. The binary is
pointed at them (`run --build-image example/image example/workspace`); they are not special to the
binary.

### `example/image` (Bun + Hono)
Multi-stage Bun build: a cached `install` stage runs `bun install --frozen-lockfile --production`;
the `release` stage copies prod `node_modules` plus `server.ts`, `index.html`, `package.json`.
`ENTRYPOINT ["bun", "run", "server.ts"]`, exposes 8080.

`server.ts` reads `OPENAI_BASE_URL`/`OPENAI_API_KEY`/`OPENAI_MODEL` (forwarded from `.env`), registers
an in-memory OpenAI-compatible provider/model via `@earendil-works/pi-coding-agent`, and serves:
- `GET /` → `index.html` (a form that POSTs to `/ask`).
- `POST /ask` → opens a fresh agent session rooted at `/workspace` with read-only tools
  (`read`, `grep`, `find`, `ls`), runs the prompt, and returns the assistant text.

The agent only reads the mounted workspace, and the mount is read-only, so a request can't modify
host files.

## Tests (`Tests/ContainerPrimerTests/`)

Swift Testing over the pure host logic:
- `DotEnvTests` — parsing edge cases.
- `CacheKeyTests` — SHA-256 hashing is deterministic, hex, and input-sensitive.
- `ImageSourceTests` — cache-validity rules for registry vs build sources, including context edits.
- `RootfsMetadataTests` — JSON round-trip.

VM boot, image building, and unpacking are not unit-tested (they need an engine, the kernel, and the
virtualization entitlement); they're exercised by running the binary.

## Distribution note

The binary must be code-signed with the `com.apple.security.virtualization` entitlement to start a
VM. That happens at build time (the Makefile signs after `swift build`); it can't be done by the
runtime binary, so a distributed build ships already signed.
