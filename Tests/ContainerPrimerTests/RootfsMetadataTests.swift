import Foundation
import Testing

@testable import ContainerPrimer

@Suite struct RootfsMetadataTests {
  @Test func writeThenLoadRoundTrips() throws {
    let metadata = RootfsMetadata(
      cacheKey: "abc123",
      imageReference: "registry/image:tag",
      imageDigest: "sha256:abc123",
      rootfsSizeInBytes: 4096,
      diskSizeInBytes: 8_589_934_592,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("meta-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try metadata.write(to: url)
    let loaded = try RootfsMetadata.load(from: url)

    #expect(loaded == metadata)
  }
}
