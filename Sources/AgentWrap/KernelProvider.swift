import ArgumentParser
import Foundation

/// Provides the Linux kernel the VM boots, downloading and caching it on first
/// use so the binary needs no external setup step.
struct KernelProvider {
  /// Kata Containers release the kernel is extracted from.
  static let kataVersion = "3.17.0"

  /// Destination cache path for the kernel (see `CacheStore.kernel`).
  let kernel: URL

  /// Return the cached kernel path, downloading and extracting it if missing.
  func ensureKernel() async throws -> URL {
    if FileManager.default.fileExists(atPath: kernel.path) { return kernel }

    print("Downloading Linux kernel (Kata \(Self.kataVersion))...")
    let url = URL(
      string:
        "https://github.com/kata-containers/kata-containers/releases/download/\(Self.kataVersion)/kata-static-\(Self.kataVersion)-arm64.tar.xz"
    )!

    let (downloaded, response) = try await URLSession.shared.download(from: url)
    defer { try? FileManager.default.removeItem(at: downloaded) }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw ValidationError("kernel download failed: \(url.absoluteString)")
    }

    let extractDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("primer-kernel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extractDir) }

    // Give the download a recognizable name, then let BSD tar autodetect xz.
    let archive = extractDir.appendingPathComponent("kata.tar.xz")
    try FileManager.default.moveItem(at: downloaded, to: archive)
    try Self.runTar(["-xf", archive.path, "-C", extractDir.path])

    // Kata ships the actual kernel as `vmlinux-<kver>`; copy that file out.
    let kataDir = extractDir.appendingPathComponent("opt/kata/share/kata-containers")
    let names = try FileManager.default.contentsOfDirectory(atPath: kataDir.path)
    guard let kernelName = names.first(where: { $0.hasPrefix("vmlinux-") }) else {
      throw ValidationError("kernel (vmlinux-*) not found in Kata \(Self.kataVersion) archive")
    }

    try FileManager.default.createDirectory(
      at: kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try RootfsFileSystem.replaceItem(at: kernel, with: kataDir.appendingPathComponent(kernelName))
    print("Cached kernel at \(kernel.path)")
    return kernel
  }

  private static func runTar(_ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ValidationError("tar failed (exit \(process.terminationStatus))")
    }
  }
}
