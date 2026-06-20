import ArgumentParser
import Containerization
import ContainerizationArchive
import ContainerizationOS
import Foundation

/// Builds and caches `.local/rootfs.ext4` from `.local/image.tar`, skipping the
/// work when the existing cache already matches the current image.
struct RootfsPreparer {
  let paths: ProjectPaths
  let imageStore: ImageStore

  init(paths: ProjectPaths = ProjectPaths(), imageStore: ImageStore = .default) {
    self.paths = paths
    self.imageStore = imageStore
  }

  func prepare(force: Bool) async throws {
    guard FileManager.default.fileExists(atPath: paths.imageTar.path) else {
      throw ValidationError(
        "image archive not found: \(paths.imageTar.path). Run `make .local/image.tar`.")
    }

    try FileManager.default.createDirectory(
      at: paths.localDirectory, withIntermediateDirectories: true)
    try RootfsFileSystem.removeInterruptedPrepareFiles(in: paths.localDirectory)

    if !force,
      let metadata = try? RootfsMetadata.load(from: paths.metadata),
      FileManager.default.fileExists(atPath: paths.cachedRootfs.path),
      let currentArchive = try? ImageArchiveFingerprint(url: paths.imageTar),
      metadata.imageArchive == currentArchive
    {
      if let image = try? await imageStore.get(reference: metadata.imageReference),
        image.digest == metadata.imageDigest
      {
        print("Prepared rootfs is up to date at \(paths.cachedRootfs.path)")
        return
      }
    }

    let image = try await loadImageArchive(at: paths.imageTar)
    let tempRootfs = paths.localDirectory.appendingPathComponent("rootfs-\(UUID().uuidString).ext4")
    let tempMetadata = paths.localDirectory.appendingPathComponent(
      "rootfs-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: tempRootfs)
      try? FileManager.default.removeItem(at: tempMetadata)
    }

    print("Unpacking \(image.reference) into cached rootfs...")
    let unpacker = EXT4Unpacker(blockSizeInBytes: 1.gib())
    _ = try await unpacker.unpack(image, for: .current, at: tempRootfs)

    let rootfsValues = try tempRootfs.resourceValues(forKeys: [.fileSizeKey])
    let rootfsSize = rootfsValues.fileSize ?? 0
    let metadata = RootfsMetadata(
      imageReference: image.reference,
      imageDigest: image.digest,
      imageArchive: try ImageArchiveFingerprint(url: paths.imageTar),
      rootfsSizeInBytes: UInt64(rootfsSize),
      createdAt: Date()
    )
    try metadata.write(to: tempMetadata)

    try RootfsFileSystem.replaceItem(at: paths.cachedRootfs, with: tempRootfs)
    try RootfsFileSystem.replaceItem(at: paths.metadata, with: tempMetadata)
    print("Prepared rootfs cache at \(paths.cachedRootfs.path)")
  }

  private func loadImageArchive(at imageTar: URL) async throws -> Image {
    print("Loading image from \(imageTar.path)...")

    let extractDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("primer-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: extractDir)
    }

    let reader = try ArchiveReader(file: imageTar)
    let rejectedPaths = try reader.extractContents(to: extractDir)
    let images = try await imageStore.load(from: extractDir)
    for rejectedPath in rejectedPaths {
      print("warning: skipped image archive member \(rejectedPath)")
    }
    guard let image = images.first else {
      throw ValidationError("no image found in \(imageTar.path)")
    }
    return image
  }
}
