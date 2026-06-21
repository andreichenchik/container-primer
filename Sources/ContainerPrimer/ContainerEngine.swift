import ArgumentParser
import Foundation

/// Drives a host container engine (podman or docker) to build an image context
/// into a temporary OCI archive. Prefers podman, falls back to docker buildx.
struct ContainerEngine {
  enum Engine: String {
    case podman
    case docker
  }

  let engine: Engine

  /// Pick the first ready engine, preferring podman. "Ready" means installed and
  /// its backend (podman machine / docker daemon) responds to `info`.
  static func select() throws -> ContainerEngine {
    for engine in [Engine.podman, .docker] where run(engine.rawValue, ["info"], quiet: true) == 0 {
      return ContainerEngine(engine: engine)
    }
    throw ValidationError(
      """
      No working container engine found. Start one and retry:
        podman -> podman machine start
        docker -> start Colima or Docker Desktop
      """)
  }

  /// Build `containerfile` against `contextDir` into a temporary OCI-archive tar
  /// tagged `tag`, returning the tar URL. The caller deletes it after loading.
  func build(contextDir: URL, containerfile: URL, tag: String) throws -> URL {
    let outputTar = FileManager.default.temporaryDirectory
      .appendingPathComponent("primer-image-\(UUID().uuidString).tar")
    let platform = "linux/arm64"
    print("Building image with \(engine.rawValue)...")

    switch engine {
    case .podman:
      try check(
        "podman",
        ["build", "--platform", platform, "-t", tag, "-f", containerfile.path, contextDir.path])
      try check("podman", ["save", "--format", "oci-archive", "-o", outputTar.path, tag])
    case .docker:
      // Colima's default docker driver can't use the OCI exporter, so build with
      // a docker-container buildx builder (created on demand, idempotent).
      let builder = "primer-builder"
      if Self.run("docker", ["buildx", "inspect", builder], quiet: true) != 0 {
        try check(
          "docker", ["buildx", "create", "--name", builder, "--driver", "docker-container"])
      }
      try check(
        "docker",
        [
          "buildx", "build", "--builder", builder,
          "--platform", platform, "--provenance=false", "--sbom=false",
          "-t", tag, "-f", containerfile.path,
          "--output", "type=oci,dest=\(outputTar.path)", contextDir.path,
        ])
    }
    return outputTar
  }

  /// Run a tool, throwing if it exits non-zero.
  private func check(_ tool: String, _ args: [String]) throws {
    let status = Self.run(tool, args)
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
