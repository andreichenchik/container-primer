import Foundation

/// System cache locations for ContainerPrimer, under Application Support.
///
/// Holds the auto-downloaded kernel and one rootfs snapshot per image cache key.
/// These are expensive to regenerate (kernel download, container-engine build),
/// so they live in a persistent location instead of a purgeable cache.
struct CacheStore {
  /// Root of the cache, e.g. `~/Library/Application Support/ContainerPrimer`.
  let base: URL

  init(base: URL) {
    self.base = base
  }

  /// The per-user cache under `Application Support/ContainerPrimer`.
  static func `default`() throws -> CacheStore {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return CacheStore(base: appSupport.appendingPathComponent("ContainerPrimer", isDirectory: true))
  }

  /// Cached Linux kernel (`vmlinux`), auto-downloaded on first use.
  var kernel: URL {
    base.appendingPathComponent("kernel", isDirectory: true).appendingPathComponent("vmlinux")
  }

  /// A cached rootfs snapshot and its metadata for one image cache key.
  struct Snapshot {
    let directory: URL
    let rootfs: URL
    let metadata: URL
  }

  /// Snapshot locations for `key`. Different images/contexts map to different
  /// keys, so each gets its own cached rootfs.
  func snapshot(forKey key: String) -> Snapshot {
    let dir = base.appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(key, isDirectory: true)
    return Snapshot(
      directory: dir,
      rootfs: dir.appendingPathComponent("rootfs.ext4"),
      metadata: dir.appendingPathComponent("rootfs.json"))
  }
}
