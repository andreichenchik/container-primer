import Foundation

/// Describes a cached rootfs snapshot and the image it was unpacked from, so a
/// run can verify the cache still matches the requested source before booting.
struct RootfsMetadata: Codable, Equatable {
  /// Stable key identifying the image source this snapshot was built for.
  let cacheKey: String
  let imageReference: String
  let imageDigest: String
  let rootfsSizeInBytes: UInt64
  /// Usable rootfs capacity the snapshot was built with; a change rebuilds it.
  let diskSizeInBytes: UInt64
  let createdAt: Date

  static func load(from url: URL) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: Data(contentsOf: url))
  }

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url)
  }
}
