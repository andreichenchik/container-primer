import Foundation
import Testing

@testable import ContainerPrimer

@Suite struct ImageArchiveFingerprintTests {
  /// Write `contents` to a fresh temp file and return its URL, removed at the
  /// end of the test.
  private func tempFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("fingerprint-\(UUID().uuidString)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test func reflectsFileSize() throws {
    let url = try tempFile("hello")
    defer { try? FileManager.default.removeItem(at: url) }

    let fingerprint = try ImageArchiveFingerprint(url: url)
    #expect(fingerprint.sizeInBytes == 5)
  }

  @Test func equalForSameFile() throws {
    let url = try tempFile("same")
    defer { try? FileManager.default.removeItem(at: url) }

    let a = try ImageArchiveFingerprint(url: url)
    let b = try ImageArchiveFingerprint(url: url)
    #expect(a == b)
  }

  @Test func differsAfterRewrite() throws {
    let url = try tempFile("first")
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try ImageArchiveFingerprint(url: url)

    // Ensure a distinct modification time, then change the size. Read through a
    // fresh URL because URL caches resource values per instance.
    Thread.sleep(forTimeInterval: 0.01)
    try "first-and-longer".write(to: url, atomically: true, encoding: .utf8)
    let after = try ImageArchiveFingerprint(url: URL(fileURLWithPath: url.path))

    #expect(before != after)
    #expect(after.sizeInBytes != before.sizeInBytes)
  }
}
