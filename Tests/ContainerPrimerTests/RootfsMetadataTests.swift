import Foundation
import Testing

@testable import ContainerPrimer

@Suite struct RootfsMetadataTests {
  private func sample() throws -> RootfsMetadata {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("meta-src-\(UUID().uuidString)")
    try "image".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    return RootfsMetadata(
      imageReference: "registry/image:tag",
      imageDigest: "sha256:abc123",
      imageArchive: try ImageArchiveFingerprint(url: url),
      rootfsSizeInBytes: 4096,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  @Test func writeThenLoadRoundTrips() throws {
    let metadata = try sample()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("meta-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try metadata.write(to: url)
    let loaded = try RootfsMetadata.load(from: url)

    #expect(loaded.imageReference == metadata.imageReference)
    #expect(loaded.imageDigest == metadata.imageDigest)
    #expect(loaded.imageArchive == metadata.imageArchive)
    #expect(loaded.rootfsSizeInBytes == metadata.rootfsSizeInBytes)
    #expect(loaded.createdAt == metadata.createdAt)
  }
}
