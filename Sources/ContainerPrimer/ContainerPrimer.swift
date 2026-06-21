import ArgumentParser

/// Command-line entry point. `run` boots the demo container from a prepared
/// rootfs; `prepare` builds that cached rootfs from the image archive.
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

    @Option(
      name: .long,
      help: "Registry reference to pull instead of the built image, e.g. docker.io/library/nginx:latest."
    )
    var image: String?

    func run() async throws {
      // A registry reference prepares the rootfs on demand (pull + unpack), so no
      // local build or container engine is required. Without it, run uses the
      // rootfs prepared from .local/image.tar.
      if let image {
        try await RootfsPreparer().prepare(
          source: RegistryImageSource(reference: image), force: false)
      }
      try await ContainerRunner().run(workspacePath: workspacePath)
    }
  }

  struct Prepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare",
      abstract: "Build the cached root filesystem from .local/image.tar or a registry reference."
    )

    @Flag(name: .long, help: "Rebuild even when the existing cache is current.")
    var force = false

    @Option(
      name: .long,
      help: "Registry reference to pull instead of the built image, e.g. docker.io/library/nginx:latest."
    )
    var image: String?

    func run() async throws {
      let paths = ProjectPaths()
      let source: ImageSource =
        if let image {
          RegistryImageSource(reference: image)
        } else {
          ArchiveImageSource(imageTar: paths.imageTar)
        }
      try await RootfsPreparer(paths: paths).prepare(source: source, force: force)
    }
  }
}
