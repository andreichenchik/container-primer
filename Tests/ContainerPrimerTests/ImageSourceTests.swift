import Foundation
import Testing

@testable import ContainerPrimer

@Suite struct ImageSourceTests {
  private func metadata(reference: String, archive: ImageArchiveFingerprint?) -> RootfsMetadata {
    RootfsMetadata(
      imageReference: reference,
      imageDigest: "sha256:abc",
      imageArchive: archive,
      rootfsSizeInBytes: 4096,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  @Test func registryCacheValidWhenReferenceMatches() throws {
    let source = RegistryImageSource(reference: "docker.io/library/nginx:latest")
    let meta = metadata(reference: "docker.io/library/nginx:latest", archive: nil)
    #expect(try source.isCacheValid(meta))
  }

  @Test func registryCacheInvalidWhenReferenceDiffers() throws {
    let source = RegistryImageSource(reference: "docker.io/library/nginx:latest")
    let meta = metadata(reference: "docker.io/library/redis:latest", archive: nil)
    #expect(try !source.isCacheValid(meta))
  }

  @Test func registryHasNoArchiveFingerprint() throws {
    #expect(try RegistryImageSource(reference: "x").archiveFingerprint() == nil)
  }

  @Test func archiveCacheValidWhenFingerprintMatches() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("img-\(UUID().uuidString).tar")
    try "image".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = ArchiveImageSource(imageTar: url)
    let fingerprint = try #require(try source.archiveFingerprint())
    let meta = metadata(reference: "local", archive: fingerprint)
    #expect(try source.isCacheValid(meta))
  }

  @Test func archiveCacheInvalidWhenArchiveMissing() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString).tar")
    let source = ArchiveImageSource(imageTar: url)
    let meta = metadata(reference: "local", archive: nil)
    #expect(try !source.isCacheValid(meta))
  }
}
