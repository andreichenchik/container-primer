import Containerization
import ContainerizationOS
import Foundation

/// Builds and caches a rootfs snapshot from an `ImageSource`, skipping the work
/// when the existing snapshot already matches the source.
struct RootfsPreparer {
  let cacheStore: CacheStore
  let imageStore: ImageStore

  init(cacheStore: CacheStore, imageStore: ImageStore = .default) {
    self.cacheStore = cacheStore
    self.imageStore = imageStore
  }

  /// Ensure a current snapshot exists for `source` and return its location.
  @discardableResult
  func prepare(source: ImageSource, force: Bool) async throws -> CacheStore.Snapshot {
    let key = try source.cacheKey
    let snapshot = cacheStore.snapshot(forKey: key)
    try FileManager.default.createDirectory(
      at: snapshot.directory, withIntermediateDirectories: true)
    try RootfsFileSystem.removeInterruptedPrepareFiles(in: snapshot.directory)

    if !force,
      let metadata = try? RootfsMetadata.load(from: snapshot.metadata),
      FileManager.default.fileExists(atPath: snapshot.rootfs.path),
      (try? source.isCacheValid(metadata)) == true
    {
      print("Prepared rootfs is up to date at \(snapshot.rootfs.path)")
      return snapshot
    }

    let image = try await source.resolve(in: imageStore)
    let tempRootfs = snapshot.directory.appendingPathComponent("rootfs-\(UUID().uuidString).ext4")
    let tempMetadata = snapshot.directory.appendingPathComponent("rootfs-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: tempRootfs)
      try? FileManager.default.removeItem(at: tempMetadata)
    }

    print("Unpacking \(image.reference) into cached rootfs...")
    let unpacker = EXT4Unpacker(blockSizeInBytes: 1.gib())
    _ = try await unpacker.unpack(image, for: .current, at: tempRootfs)

    let rootfsSize = try tempRootfs.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let metadata = RootfsMetadata(
      cacheKey: key,
      imageReference: image.reference,
      imageDigest: image.digest,
      rootfsSizeInBytes: UInt64(rootfsSize),
      createdAt: Date()
    )
    try metadata.write(to: tempMetadata)

    try RootfsFileSystem.replaceItem(at: snapshot.rootfs, with: tempRootfs)
    try RootfsFileSystem.replaceItem(at: snapshot.metadata, with: tempMetadata)
    print("Prepared rootfs cache at \(snapshot.rootfs.path)")
    return snapshot
  }
}
