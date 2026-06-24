import Foundation

/// Project-relative inputs the launcher reads from the current directory. Caches
/// (kernel, snapshots) live elsewhere — see `CacheStore`.
struct ProjectPaths {
  let root: URL

  init(root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
    self.root = root
  }

  /// Default host directory mounted at `/workspace` when none is given.
  var defaultWorkspace: URL { root.appendingPathComponent("workspace", isDirectory: true) }
}
