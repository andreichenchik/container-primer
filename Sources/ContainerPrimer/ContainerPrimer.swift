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

    func run() async throws {
      try await ContainerRunner().run(workspacePath: workspacePath)
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
      try await RootfsPreparer().prepare(force: force)
    }
  }
}
