import ArgumentParser
import Containerization
import ContainerizationOS
import Foundation

/// Boots a container from a prepared rootfs snapshot, mounting the host
/// `workspace/` and running the image's own entrypoint (or an explicit command)
/// until the process exits or a termination signal arrives. With `interactive`
/// the host terminal is attached to the process over a pty.
struct ContainerRunner {
  let cacheStore: CacheStore
  let projectPaths: ProjectPaths

  init(cacheStore: CacheStore, projectPaths: ProjectPaths = ProjectPaths()) {
    self.cacheStore = cacheStore
    self.projectPaths = projectPaths
  }

  /// Resolves the process arguments. An explicit `command` always wins; an empty
  /// command runs the image entrypoint, except in interactive mode where it
  /// defaults to a shell.
  static func resolvedCommand(interactive: Bool, command: [String]) -> [String] {
    if !command.isEmpty { return command }
    return interactive ? ["/bin/sh"] : []
  }

  /// Runs `source`'s container.
  /// - Parameters:
  ///   - command: Process arguments to run instead of the image entrypoint.
  ///   - interactive: Attach the host terminal over a pty (raw mode).
  ///   - writeWorkspace: Mount `/workspace` read-write instead of read-only.
  func run(
    source: ImageSource,
    workspacePath explicitWorkspacePath: String?,
    command: [String] = [],
    interactive: Bool = false,
    writeWorkspace: Bool = false
  ) async throws {
    let resolvedCommand = Self.resolvedCommand(interactive: interactive, command: command)
    let mountOptions = writeWorkspace ? [] : ["ro"]

    // In interactive mode forward the host terminal to the process. Created up
    // front (cheap) so the config closure can wire it; raw mode is enabled just
    // before start so the status prints below stay in cooked mode.
    let terminal: Terminal?
    if interactive {
      guard isatty(STDIN_FILENO) != 0 else {
        throw ValidationError("--interactive requires a terminal on stdin")
      }
      terminal = try Terminal(descriptor: STDIN_FILENO)
    } else {
      terminal = nil
    }
    defer { terminal?.tryReset() }

    let envKeys = DotEnv.load()
    print("Starting container primer...")

    let snapshot = cacheStore.snapshot(forKey: try source.cacheKey)
    let metadata = try loadPreparedRootfsMetadata(snapshot)

    let kernel = try await KernelProvider(kernel: cacheStore.kernel).ensureKernel()

    let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"
    print("Fetching base container filesystem...")
    var manager = try await ContainerManager(
      kernel: Kernel(path: kernel, platform: .linuxArm),
      initfsReference: initfsReference,
      network: try VmnetNetwork()
    )

    // Unique per run so multiple instances can run in parallel.
    let containerId = "primer-\(UUID().uuidString)"

    // Host directory shared into the container over virtiofs. Defaults to
    // `<cwd>/workspace`; an optional first argument points elsewhere.
    let workspacePath = explicitWorkspacePath ?? projectPaths.defaultWorkspace.path
    guard FileManager.default.fileExists(atPath: workspacePath) else {
      throw ValidationError("workspace directory not found: \(workspacePath)")
    }

    let image = try await manager.imageStore.get(reference: metadata.imageReference)
    guard image.digest == metadata.imageDigest else {
      throw ValidationError(
        "prepared image \(metadata.imageReference) no longer matches the image store. Run `prepare` again."
      )
    }

    let containerDir = manager.imageStore.path
      .appendingPathComponent("containers", isDirectory: true)
      .appendingPathComponent(containerId, isDirectory: true)
    try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
    let containerRootfs = containerDir.appendingPathComponent("rootfs.ext4")
    try RootfsFileSystem.cloneRootfs(from: snapshot.rootfs, to: containerRootfs)

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
      // Resolve `localhost` (and IPv6 loopback names) via /etc/hosts instead of DNS.
      config.hosts = .default
      // Mount the host `workspace/`; the agent reads it live, so host edits there
      // are visible without a rebuild. Read-only unless `--write` is given.
      config.mounts.append(
        .share(source: workspacePath, destination: "/workspace", options: mountOptions))
      // Working directory and base environment come from the image (WORKDIR / ENV);
      // an explicit command overrides the image entrypoint.
      if !resolvedCommand.isEmpty {
        config.process.arguments = resolvedCommand
      }
      if let terminal {
        // Start interactive sessions in the mounted workspace.
        config.process.workingDirectory = "/workspace"
        // Wire the host terminal to the process over a pty. Mirror the host's
        // TERM/COLORTERM instead of `setTerminalIO`'s hardcoded `TERM=xterm`,
        // which advertises only 8 colors and breaks 256-color/truecolor output.
        config.process.terminal = true
        config.process.stdin = terminal
        config.process.stdout = terminal
        let hostEnv = ProcessInfo.processInfo.environment
        config.process.environmentVariables.removeAll {
          $0.hasPrefix("TERM=") || $0.hasPrefix("COLORTERM=")
        }
        config.process.environmentVariables.append("TERM=\(hostEnv["TERM"] ?? "xterm-256color")")
        if let colorterm = hostEnv["COLORTERM"] {
          config.process.environmentVariables.append("COLORTERM=\(colorterm)")
        }
      } else {
        // Surface the container's logs on the host terminal.
        config.process.stdout = HostWriter(.standardOutput)
        config.process.stderr = HostWriter(.standardError)
      }
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

    if let terminal {
      // Interactive: hand the host terminal over to the guest process. Raw mode
      // forwards control chars (incl. Ctrl+C) as bytes to the shell rather than
      // signalling this process, so there is no SIGINT trap here.
      try terminal.setraw()
      try await container.start()
      try? await container.resize(to: terminal.size)

      let winch = AsyncSignalHandler.create(notify: [SIGWINCH])
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in winch.signals {
            try? await container.resize(to: terminal.size)
          }
        }
        try await container.wait()
        group.cancelAll()
      }
      return
    }

    try await container.start()

    let containerAddress = container.interfaces.first?.ipv4Address.address.description
    if let containerAddress {
      print("Container available at \(containerAddress)")
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
      // Surface the ports the container starts listening on as they appear.
      if let containerAddress {
        let watcher = PortWatcher(
          runner: ContainerCommandRunner(container: container),
          ipv4Address: containerAddress
        )
        group.addTask { await watcher.watch() }
      }
      try await container.wait()
      group.cancelAll()
    }

    print("Container stopped, cleaning up.")
  }

  private func loadPreparedRootfsMetadata(_ snapshot: CacheStore.Snapshot) throws -> RootfsMetadata
  {
    guard FileManager.default.fileExists(atPath: snapshot.rootfs.path) else {
      throw ValidationError(
        "prepared rootfs not found: \(snapshot.rootfs.path). Run `prepare` first.")
    }
    guard FileManager.default.fileExists(atPath: snapshot.metadata.path) else {
      throw ValidationError(
        "prepared rootfs metadata not found: \(snapshot.metadata.path). Run `prepare` first.")
    }
    return try RootfsMetadata.load(from: snapshot.metadata)
  }
}
