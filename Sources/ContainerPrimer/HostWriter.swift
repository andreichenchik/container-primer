import Containerization
import Foundation

/// Forwards container process output to a host file handle (stdout/stderr) so the
/// server's logs are visible on the host terminal.
final class HostWriter: @unchecked Sendable, Writer {
  private let handle: FileHandle
  init(_ handle: FileHandle) { self.handle = handle }
  func write(_ data: Data) throws {
    guard !data.isEmpty else { return }
    try handle.write(contentsOf: data)
  }
  func close() throws {}
}
