import ArgumentParser
import Foundation

/// Command-line entry point. `run` boots a container from a prepared rootfs
/// snapshot; `prepare` builds that snapshot; `clean` clears the cache.
@main
struct ContainerPrimer: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ContainerPrimer",
    abstract: "Build or pull a container image and run it in a lightweight Linux VM.",
    subcommands: [Run.self, Prepare.self, Clean.self],
    defaultSubcommand: Run.self
  )

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "run",
      abstract: "Prepare (if needed) and run a container from its rootfs snapshot."
    )

    @Argument(help: "Host workspace directory to mount read-only at /workspace.")
    var workspacePath: String?

    @OptionGroup var source: SourceOptions

    func run() async throws {
      let cacheStore = try CacheStore.default()
      let imageSource = try source.makeSource()
      try await RootfsPreparer(cacheStore: cacheStore).prepare(source: imageSource, force: false)
      try await ContainerRunner(cacheStore: cacheStore)
        .run(source: imageSource, workspacePath: workspacePath)
    }
  }

  struct Prepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare",
      abstract: "Build the cached rootfs snapshot without running it."
    )

    @Flag(name: .long, help: "Rebuild even when the existing snapshot is current.")
    var force = false

    @OptionGroup var source: SourceOptions

    func run() async throws {
      let cacheStore = try CacheStore.default()
      try await RootfsPreparer(cacheStore: cacheStore)
        .prepare(source: try source.makeSource(), force: force)
    }
  }

  struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "clean",
      abstract: "Remove the cached kernel and all rootfs snapshots."
    )

    func run() async throws {
      let cacheStore = try CacheStore.default()
      guard FileManager.default.fileExists(atPath: cacheStore.base.path) else {
        print("Nothing to clean at \(cacheStore.base.path)")
        return
      }
      try FileManager.default.removeItem(at: cacheStore.base)
      print("Removed \(cacheStore.base.path)")
    }
  }
}

/// Selects where the image comes from: a registry pull or a local build. Exactly
/// one of `--image` / `--build-image` must be given.
struct SourceOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Registry reference to pull, e.g. docker.io/library/nginx:latest.")
  var image: String?

  @Option(
    name: .long,
    help: "Build context directory or Containerfile to build with podman/docker.")
  var buildImage: String?

  func makeSource() throws -> ImageSource {
    switch (image, buildImage) {
    case (let reference?, nil):
      return RegistryImageSource(reference: reference)
    case (nil, let path?):
      return try Self.buildSource(path: path)
    case (nil, nil):
      throw ValidationError("provide --image <ref> or --build-image <path>.")
    case (.some, .some):
      throw ValidationError("--image and --build-image are mutually exclusive.")
    }
  }

  /// Resolve `--build-image <path>` into a context directory + Containerfile.
  /// `path` is either a directory (uses its Containerfile/Dockerfile) or a
  /// Containerfile path (its directory is the context).
  private static func buildSource(path: String) throws -> BuildImageSource {
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw ValidationError("build context not found: \(path)")
    }
    guard isDirectory.boolValue else {
      return BuildImageSource(contextDir: url.deletingLastPathComponent(), containerfile: url)
    }
    for name in ["Containerfile", "Dockerfile"] {
      let candidate = url.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return BuildImageSource(contextDir: url, containerfile: candidate)
      }
    }
    throw ValidationError("no Containerfile or Dockerfile in \(path)")
  }
}
