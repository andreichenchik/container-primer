import Containerization
import Foundation

/// Filesystem locations the launcher reads and writes, rooted at the project
/// working directory. Defaults to the current directory.
struct ProjectPaths {
  let root: URL

  init(root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
    self.root = root
  }

  var localDirectory: URL { root.appendingPathComponent(".local", isDirectory: true) }
  var imageTar: URL { localDirectory.appendingPathComponent("image.tar") }
  var kernel: URL { localDirectory.appendingPathComponent("vmlinux") }
  var cachedRootfs: URL { localDirectory.appendingPathComponent("rootfs.ext4") }
  var metadata: URL { localDirectory.appendingPathComponent("rootfs.json") }

  func containerDirectory(imageStore: ImageStore, id: String) -> URL {
    imageStore.path
      .appendingPathComponent("containers", isDirectory: true)
      .appendingPathComponent(id, isDirectory: true)
  }
}
