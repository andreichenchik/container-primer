import Containerization
import Foundation

/// Collects container process output in memory so it can be read back on the
/// host. Use when you need a command's stdout as a value (e.g. probing the
/// guest), rather than streaming it to the terminal like `HostWriter`.
final class BufferWriter: @unchecked Sendable, Writer {
  private let lock = NSLock()
  private var buffer = Data()

  func write(_ data: Data) throws {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
  }

  func close() throws {}

  /// The bytes written so far, decoded as UTF-8.
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: buffer, as: UTF8.self)
  }
}
