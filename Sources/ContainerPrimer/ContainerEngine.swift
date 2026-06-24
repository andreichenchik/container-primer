import ArgumentParser
import Foundation

/// Drives Apple's `container` CLI to build an image context into a temporary OCI
/// archive. Requires the `container` system service to be running.
enum ContainerEngine {
  /// Verify the `container` CLI is installed and its system service is running.
  /// Never starts the service; surfaces the commands for the user to run.
  static func ensureAvailable() throws {
    guard run("container", ["system", "status"], quiet: true) == 0 else {
      throw ValidationError(
        """
        Apple's `container` CLI is required to build images (--build-image).
          install: brew install container
          start:   container system start   (or: brew services start container)
        """)
    }
  }

  /// Build `containerfile` against `contextDir` into a temporary OCI-archive tar
  /// tagged `tag`, returning the tar URL. The caller deletes it after loading.
  static func build(contextDir: URL, containerfile: URL, tag: String) throws -> URL {
    let outputTar = FileManager.default.temporaryDirectory
      .appendingPathComponent("primer-image-\(UUID().uuidString).tar")
    let platform = "linux/arm64"
    print("Building image with container...")
    // `container build` loads the result into container's own image store, so build
    // there and then export an OCI archive the framework's image store can load.
    try check(
      "container",
      [
        "build", "--platform", platform, "--progress", "plain",
        "--tag", tag, "--file", containerfile.path, contextDir.path,
      ])
    defer { _ = run("container", ["image", "delete", tag], quiet: true) }
    try check(
      "container",
      ["image", "save", "--platform", platform, "--output", outputTar.path, tag])
    return outputTar
  }

  /// Run a tool, throwing if it exits non-zero.
  private static func check(_ tool: String, _ args: [String]) throws {
    let status = run(tool, args)
    guard status == 0 else {
      throw ValidationError("\(tool) \(args.first ?? "") failed (exit \(status))")
    }
  }

  /// Run `tool` (resolved from PATH) with `args`, returning its exit status.
  /// When `quiet`, output is discarded; otherwise it streams to the terminal.
  private static func run(_ tool: String, _ args: [String], quiet: Bool = false) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    if quiet {
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
    }
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    } catch {
      return 127
    }
  }
}
