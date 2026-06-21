import ArgumentParser
import Containerization
import ContainerizationArchive
import Foundation

/// Supplies the container image to unpack into a cached rootfs. Implementations
/// either build a local context with a container engine or pull a registry
/// reference.
protocol ImageSource {
  /// Build or pull the image into `store` and return it.
  func resolve(in store: ImageStore) async throws -> Image

  /// Stable key identifying this source; selects the snapshot cache slot.
  var cacheKey: String { get throws }
}

extension ImageSource {
  /// A cached rootfs is reusable when it was built for the same source key.
  func isCacheValid(_ metadata: RootfsMetadata) throws -> Bool {
    metadata.cacheKey == (try cacheKey)
  }
}

/// Builds an image from a local context with podman or docker. The build output
/// is loaded into `store` and the intermediate archive is discarded.
struct BuildImageSource: ImageSource {
  let contextDir: URL
  let containerfile: URL

  var cacheKey: String {
    get throws { try CacheKey.forContext(dir: contextDir, containerfile: containerfile) }
  }

  func resolve(in store: ImageStore) async throws -> Image {
    let tag = "containerprimer.local/build-\(try cacheKey.prefix(12)):latest"
    let engine = try ContainerEngine.select()
    let archive = try engine.build(contextDir: contextDir, containerfile: containerfile, tag: tag)
    defer { try? FileManager.default.removeItem(at: archive) }

    let extractDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("primer-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extractDir) }

    print("Loading built image into the store...")
    let reader = try ArchiveReader(file: archive)
    let rejectedPaths = try reader.extractContents(to: extractDir)
    let images = try await store.load(from: extractDir)
    for rejectedPath in rejectedPaths {
      print("warning: skipped image archive member \(rejectedPath)")
    }
    guard let image = images.first else {
      throw ValidationError("no image found in build output")
    }
    return image
  }
}

/// Pulls an image from a registry by reference, e.g. `docker.io/library/nginx:latest`.
/// No local build or container engine required.
struct RegistryImageSource: ImageSource {
  let reference: String

  var cacheKey: String { CacheKey.hashing("registry:" + reference) }

  func resolve(in store: ImageStore) async throws -> Image {
    print("Pulling image \(reference)...")
    return try await store.get(reference: reference, pull: true)
  }
}
