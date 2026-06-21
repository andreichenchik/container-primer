import ArgumentParser
import Containerization
import ContainerizationArchive
import Foundation

/// Supplies the container image to unpack into the cached rootfs. Implementations
/// either load a local OCI archive or pull a reference from a registry.
protocol ImageSource {
  /// Load or pull the image into `store` and return it.
  func resolve(in store: ImageStore) async throws -> Image

  /// True when a rootfs cached from `metadata` is still valid for this source.
  func isCacheValid(_ metadata: RootfsMetadata) throws -> Bool

  /// Archive fingerprint to record in metadata, or `nil` for registry sources.
  func archiveFingerprint() throws -> ImageArchiveFingerprint?
}

/// Loads an image from a local OCI archive (`.local/image.tar`).
struct ArchiveImageSource: ImageSource {
  let imageTar: URL

  func resolve(in store: ImageStore) async throws -> Image {
    guard FileManager.default.fileExists(atPath: imageTar.path) else {
      throw ValidationError("image archive not found: \(imageTar.path). Run `make .local/image.tar`.")
    }
    print("Loading image from \(imageTar.path)...")

    let extractDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("primer-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extractDir) }

    let reader = try ArchiveReader(file: imageTar)
    let rejectedPaths = try reader.extractContents(to: extractDir)
    let images = try await store.load(from: extractDir)
    for rejectedPath in rejectedPaths {
      print("warning: skipped image archive member \(rejectedPath)")
    }
    guard let image = images.first else {
      throw ValidationError("no image found in \(imageTar.path)")
    }
    return image
  }

  func isCacheValid(_ metadata: RootfsMetadata) throws -> Bool {
    guard FileManager.default.fileExists(atPath: imageTar.path) else { return false }
    return metadata.imageArchive == (try ImageArchiveFingerprint(url: imageTar))
  }

  func archiveFingerprint() throws -> ImageArchiveFingerprint? {
    try ImageArchiveFingerprint(url: imageTar)
  }
}

/// Pulls an image from a registry by reference, e.g. `docker.io/library/nginx:latest`.
/// No local build or container engine required.
struct RegistryImageSource: ImageSource {
  let reference: String

  func resolve(in store: ImageStore) async throws -> Image {
    print("Pulling image \(reference)...")
    return try await store.get(reference: reference, pull: true)
  }

  func isCacheValid(_ metadata: RootfsMetadata) -> Bool {
    metadata.imageReference == reference
  }

  func archiveFingerprint() -> ImageArchiveFingerprint? { nil }
}
