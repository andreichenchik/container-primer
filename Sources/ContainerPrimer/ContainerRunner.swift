import ArgumentParser
import Containerization
import ContainerizationOS
import Foundation

/// Boots a container from the prepared rootfs, mounting the host `workspace/`
/// read-only and running the image's own entrypoint until the server exits or a
/// termination signal arrives.
struct ContainerRunner {
  let paths: ProjectPaths

  init(paths: ProjectPaths = ProjectPaths()) {
    self.paths = paths
  }

  func run(workspacePath explicitWorkspacePath: String?) async throws {
    let envKeys = DotEnv.load()
    print("Starting container primer...")

    let metadata = try loadPreparedRootfsMetadata()

    let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"
    print("Fetching base container filesystem...")
    var manager = try await ContainerManager(
      kernel: Kernel(path: paths.kernel, platform: .linuxArm),
      initfsReference: initfsReference,
      network: try VmnetNetwork()
    )

    // Unique per run so multiple instances can run in parallel.
    let containerId = "primer-\(UUID().uuidString)"

    // Host directory shared into the container over virtiofs. Defaults to
    // `<cwd>/workspace`; an optional first argument points elsewhere.
    let workspacePath =
      explicitWorkspacePath
      ?? FileManager.default.currentDirectoryPath + "/workspace"
    guard FileManager.default.fileExists(atPath: workspacePath) else {
      throw ValidationError("workspace directory not found: \(workspacePath)")
    }

    let image = try await manager.imageStore.get(reference: metadata.imageReference)
    guard image.digest == metadata.imageDigest else {
      throw ValidationError(
        "prepared image \(metadata.imageReference) no longer matches the image store. Run `make prepare`."
      )
    }

    let containerDir = paths.containerDirectory(imageStore: manager.imageStore, id: containerId)
    try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
    let containerRootfs = containerDir.appendingPathComponent("rootfs.ext4")
    try RootfsFileSystem.cloneRootfs(from: paths.cachedRootfs, to: containerRootfs)

    print("Creating container from prepared rootfs for \(image.reference)...")

    let rootfs = Mount.block(
      format: "ext4",
      source: containerRootfs.path,
      destination: "/"
    )

    let container = try await manager.create(
      containerId,
      image: image,
      rootfs: rootfs
    ) { @Sendable config in
      config.cpus = 2
      config.memoryInBytes = 512.mib()
      // Mount the host `workspace/` read-only; the agent reads it live, so
      // host edits there are visible without a rebuild.
      config.mounts.append(
        .share(source: workspacePath, destination: "/workspace", options: ["ro"]))
      // The command, working directory, and base environment come from the image
      // (ENTRYPOINT / WORKDIR / ENV).
      // Surface the container's logs on the host terminal.
      config.process.stdout = HostWriter(.standardOutput)
      config.process.stderr = HostWriter(.standardError)
      // Forward every variable declared in `.env` (shell overrides still win).
      for key in envKeys {
        if let value = ProcessInfo.processInfo.environment[key] {
          config.process.environmentVariables.append("\(key)=\(value)")
        }
      }
    }

    defer {
      try? manager.delete(containerId)
    }

    print("Starting container...")
    try await container.create()
    try await container.start()

    if let interface = container.interfaces.first {
      print("Container available at \(interface.ipv4Address.address.description)")
    }
    print("Press Ctrl+C to stop.")

    // Run until the server exits or we receive SIGINT/SIGTERM. On signal we
    // stop the container, which lets wait() return and the deferred delete
    // tear the container down so nothing is persisted.
    let signals = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM])
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in signals.signals {
          try? await container.stop()
          return
        }
      }
      try await container.wait()
      group.cancelAll()
    }

    print("Container stopped, cleaning up.")
  }

  private func loadPreparedRootfsMetadata() throws -> RootfsMetadata {
    guard FileManager.default.fileExists(atPath: paths.cachedRootfs.path) else {
      throw ValidationError(
        "prepared rootfs not found: \(paths.cachedRootfs.path). Run `make prepare`.")
    }
    guard FileManager.default.fileExists(atPath: paths.metadata.path) else {
      throw ValidationError(
        "prepared rootfs metadata not found: \(paths.metadata.path). Run `make prepare`.")
    }

    let metadata = try RootfsMetadata.load(from: paths.metadata)
    // Only archive-sourced rootfs are tied to .local/image.tar; registry-pulled
    // ones (imageArchive == nil) ignore a stale leftover archive.
    if metadata.imageArchive != nil, FileManager.default.fileExists(atPath: paths.imageTar.path) {
      let currentArchive = try ImageArchiveFingerprint(url: paths.imageTar)
      guard currentArchive == metadata.imageArchive else {
        throw ValidationError("prepared rootfs is older than .local/image.tar. Run `make prepare`.")
      }
    }
    return metadata
  }
}
