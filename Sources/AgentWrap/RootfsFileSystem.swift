import Darwin
import Foundation

/// Filesystem helpers for managing rootfs images: copy-on-write cloning, atomic
/// replacement, and cleanup of files left behind by an interrupted prepare.
enum RootfsFileSystem {
  /// Clone `source` to `destination`, preferring an APFS copy-on-write clone and
  /// falling back to a plain copy when cloning is unavailable.
  static func cloneRootfs(from source: URL, to destination: URL) throws {
    let result = Darwin.clonefile(source.path, destination.path, 0)
    if result != 0 {
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  /// Move `source` onto `destination`, removing any existing file first.
  static func replaceItem(at destination: URL, with source: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: source, to: destination)
  }

  /// Remove temporary `rootfs-*.ext4` / `rootfs-*.json` files left behind by an
  /// interrupted prepare.
  static func removeInterruptedPrepareFiles(in directory: URL) throws {
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
