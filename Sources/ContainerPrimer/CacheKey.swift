import CryptoKit
import Foundation

/// Derives the stable key that identifies a rootfs snapshot's image source, so
/// different references/contexts map to different cached snapshots.
enum CacheKey {
  /// SHA-256 (hex) of an arbitrary string.
  static func hashing(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Fingerprint of a build context: the path, size, and mtime of every regular
  /// file under `dir`, plus the Containerfile. Cheap (no content reads) and
  /// changes whenever a file is edited, added, or removed.
  static func forContext(dir: URL, containerfile: URL) throws -> String {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    var entries: [String] = []
    if let enumerator = FileManager.default.enumerator(
      at: dir, includingPropertiesForKeys: Array(keys))
    {
      for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else { continue }
        entries.append(fingerprint(of: url, relativeTo: dir, values: values))
      }
    }
    entries.append(
      fingerprint(
        of: containerfile, relativeTo: dir,
        values: try containerfile.resourceValues(forKeys: keys)))
    entries.sort()
    return hashing(entries.joined(separator: "\n"))
  }

  private static func fingerprint(
    of url: URL, relativeTo dir: URL, values: URLResourceValues
  ) -> String {
    let rel =
      url.path.hasPrefix(dir.path + "/")
      ? String(url.path.dropFirst(dir.path.count + 1)) : url.lastPathComponent
    let size = values.fileSize ?? 0
    let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    return "\(rel)\t\(size)\t\(mtime)"
  }
}
