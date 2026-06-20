import ArgumentParser
import Foundation

/// Size and modification time of the image archive, used to detect when the
/// cached rootfs is stale relative to `.local/image.tar`.
struct ImageArchiveFingerprint: Codable, Equatable {
  let sizeInBytes: UInt64
  let modificationTimeSince1970: TimeInterval

  init(url: URL) throws {
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey,
      .contentModificationDateKey,
    ])
    guard let size = values.fileSize else {
      throw ValidationError("could not read image archive size: \(url.path)")
    }
    guard let modificationDate = values.contentModificationDate else {
      throw ValidationError("could not read image archive modification time: \(url.path)")
    }

    self.sizeInBytes = UInt64(size)
    self.modificationTimeSince1970 = modificationDate.timeIntervalSince1970
  }
}

/// Describes the cached rootfs and the image it was unpacked from, so a run can
/// verify the cache still matches the current image before booting.
struct RootfsMetadata: Codable {
  let imageReference: String
  let imageDigest: String
  let imageArchive: ImageArchiveFingerprint
  let rootfsSizeInBytes: UInt64
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
