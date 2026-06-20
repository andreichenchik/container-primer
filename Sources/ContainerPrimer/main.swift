import ArgumentParser
import Containerization
import ContainerizationArchive
import ContainerizationOS
import Darwin
import Foundation

/// Forwards container process output to a host file handle (stdout/stderr) so the
/// server's logs are visible on the host terminal.
final class HostWriter: @unchecked Sendable, Writer {
  private let handle: FileHandle
  init(_ handle: FileHandle) { self.handle = handle }
  func write(_ data: Data) throws {
    guard !data.isEmpty else { return }
    try handle.write(contentsOf: data)
  }
  func close() throws {}
}

@main
struct ContainerPrimer: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ContainerPrimer",
    abstract: "Prepare and run the ContainerPrimer demo container.",
    subcommands: [Run.self, Prepare.self],
    defaultSubcommand: Run.self
  )

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "run",
      abstract: "Run the server from a prepared root filesystem."
    )

    @Argument(help: "Host workspace directory to mount at /workspace.")
    var workspacePath: String?

    func run() async throws {
      try await ContainerPrimer.run(workspacePath: workspacePath)
    }
  }

  struct Prepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare",
      abstract: "Build the cached root filesystem from .local/image.tar."
    )

    @Flag(name: .long, help: "Rebuild even when the existing cache is current.")
    var force = false

    func run() async throws {
      try await ContainerPrimer.prepare(force: force)
    }
  }

  private struct Paths {
    let root: URL

    init(root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
      self.root = root
    }

    var localDirectory: URL { root.appendingPathComponent(".local", isDirectory: true) }
    var imageTar: URL { localDirectory.appendingPathComponent("image.tar") }
    var kernel: URL { localDirectory.appendingPathComponent("vmlinux") }
    var cachedRootfs: URL { localDirectory.appendingPathComponent("rootfs.ext4") }
    var metadata: URL { localDirectory.appendingPathComponent("rootfs.json") }

    func containerDirectory(imageStore: ImageStore, id: String) -> URL {
      imageStore.path
        .appendingPathComponent("containers", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    }
  }

  private struct ImageArchiveFingerprint: Codable, Equatable {
    let sizeInBytes: UInt64
    let modificationTimeSince1970: TimeInterval

    init(url: URL) throws {
      let values = try url.resourceValues(forKeys: [
        .fileSizeKey,
        .contentModificationDateKey,
      ])
      guard let size = values.fileSize else {
        throw ValidationError("could not read image archive size: \(url.path)")
      }
      guard let modificationDate = values.contentModificationDate else {
        throw ValidationError("could not read image archive modification time: \(url.path)")
      }

      self.sizeInBytes = UInt64(size)
      self.modificationTimeSince1970 = modificationDate.timeIntervalSince1970
    }
  }

  private struct RootfsMetadata: Codable {
    let imageReference: String
    let imageDigest: String
    let imageArchive: ImageArchiveFingerprint
    let rootfsSizeInBytes: UInt64
    let createdAt: Date

    static func load(from url: URL) throws -> Self {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(Self.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(self).write(to: url)
    }
  }

  /// Load `KEY=VALUE` pairs from a `.env` file in the current directory into the
  /// process environment and return the keys it declared. Existing environment
  /// variables take precedence, so the shell can still override `.env`. Missing
  /// file is a no-op. The returned keys are the launcher's contract for which
  /// variables to forward into the container.
  static func loadDotEnv() -> [String] {
    let path = FileManager.default.currentDirectoryPath + "/.env"
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var keys: [String] = []
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("export ") { line.removeFirst("export ".count) }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value = String(value.dropFirst().dropLast())
      }
      if !key.isEmpty {
        setenv(key, value, 0)
        keys.append(key)
      }
    }
    return keys
  }

  private static func prepare(force: Bool) async throws {
    let paths = Paths()
    let imageStore = ImageStore.default

    guard FileManager.default.fileExists(atPath: paths.imageTar.path) else {
      throw ValidationError(
        "image archive not found: \(paths.imageTar.path). Run `make .local/image.tar`.")
    }

    try FileManager.default.createDirectory(
      at: paths.localDirectory, withIntermediateDirectories: true)
    try removeInterruptedPrepareFiles(in: paths.localDirectory)

    if !force,
      let metadata = try? RootfsMetadata.load(from: paths.metadata),
      FileManager.default.fileExists(atPath: paths.cachedRootfs.path),
      let currentArchive = try? ImageArchiveFingerprint(url: paths.imageTar),
      metadata.imageArchive == currentArchive
    {
      if let image = try? await imageStore.get(reference: metadata.imageReference),
        image.digest == metadata.imageDigest
      {
        print("Prepared rootfs is up to date at \(paths.cachedRootfs.path)")
        return
      }
    }

    let image = try await loadImageArchive(at: paths.imageTar, into: imageStore)
    let tempRootfs = paths.localDirectory.appendingPathComponent("rootfs-\(UUID().uuidString).ext4")
    let tempMetadata = paths.localDirectory.appendingPathComponent(
      "rootfs-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: tempRootfs)
      try? FileManager.default.removeItem(at: tempMetadata)
    }

    print("Unpacking \(image.reference) into cached rootfs...")
    let unpacker = EXT4Unpacker(blockSizeInBytes: 1.gib())
    _ = try await unpacker.unpack(image, for: .current, at: tempRootfs)

    let rootfsValues = try tempRootfs.resourceValues(forKeys: [.fileSizeKey])
    let rootfsSize = rootfsValues.fileSize ?? 0
    let metadata = RootfsMetadata(
      imageReference: image.reference,
      imageDigest: image.digest,
      imageArchive: try ImageArchiveFingerprint(url: paths.imageTar),
      rootfsSizeInBytes: UInt64(rootfsSize),
      createdAt: Date()
    )
    try metadata.write(to: tempMetadata)

    try replaceItem(at: paths.cachedRootfs, with: tempRootfs)
    try replaceItem(at: paths.metadata, with: tempMetadata)
    print("Prepared rootfs cache at \(paths.cachedRootfs.path)")
  }

  private static func run(workspacePath explicitWorkspacePath: String?) async throws {
    let envKeys = loadDotEnv()
    print("Starting container primer...")

    let paths = Paths()
    let metadata = try loadPreparedRootfsMetadata(paths: paths)

    let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"
    print("Fetching base container filesystem...")
    var manager = try await ContainerManager(
      kernel: Kernel(path: paths.kernel, platform: .linuxArm),
      initfsReference: initfsReference,
      network: try VmnetNetwork()
    )

    // Unique per run so multiple instances can run in parallel.
    let containerId = "primer-\(UUID().uuidString)"

    // Host directory shared into the container over virtiofs. `make` runs from
    // the project root, so cwd/workspace is correct; an optional first argument
    // lets you point elsewhere (e.g. when running the binary from /var/tmp).
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
    try cloneRootfs(from: paths.cachedRootfs, to: containerRootfs)

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
      // (ENTRYPOINT / WORKDIR / ENV); the launcher stays agnostic to what runs.
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

  private static func loadImageArchive(at imageTar: URL, into imageStore: ImageStore) async throws
    -> Image
  {
    print("Loading image from \(imageTar.path)...")

    let extractDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("primer-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: extractDir)
    }

    let reader = try ArchiveReader(file: imageTar)
    let rejectedPaths = try reader.extractContents(to: extractDir)
    let images = try await imageStore.load(from: extractDir)
    for rejectedPath in rejectedPaths {
      print("warning: skipped image archive member \(rejectedPath)")
    }
    guard let image = images.first else {
      throw ValidationError("no image found in \(imageTar.path)")
    }
    return image
  }

  private static func loadPreparedRootfsMetadata(paths: Paths) throws -> RootfsMetadata {
    guard FileManager.default.fileExists(atPath: paths.cachedRootfs.path) else {
      throw ValidationError(
        "prepared rootfs not found: \(paths.cachedRootfs.path). Run `make prepare`.")
    }
    guard FileManager.default.fileExists(atPath: paths.metadata.path) else {
      throw ValidationError(
        "prepared rootfs metadata not found: \(paths.metadata.path). Run `make prepare`.")
    }

    let metadata = try RootfsMetadata.load(from: paths.metadata)
    if FileManager.default.fileExists(atPath: paths.imageTar.path) {
      let currentArchive = try ImageArchiveFingerprint(url: paths.imageTar)
      guard currentArchive == metadata.imageArchive else {
        throw ValidationError("prepared rootfs is older than .local/image.tar. Run `make prepare`.")
      }
    }
    return metadata
  }

  private static func cloneRootfs(from source: URL, to destination: URL) throws {
    let result = Darwin.clonefile(source.path, destination.path, 0)
    if result != 0 {
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  private static func replaceItem(at destination: URL, with source: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: source, to: destination)
  }

  private static func removeInterruptedPrepareFiles(in directory: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    for file in files {
      let name = file.lastPathComponent
      guard name.hasPrefix("rootfs-") && (name.hasSuffix(".ext4") || name.hasSuffix(".json")) else {
        continue
      }
      try FileManager.default.removeItem(at: file)
    }
  }
}
