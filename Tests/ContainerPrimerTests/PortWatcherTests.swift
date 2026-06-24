import Foundation
import Testing

@testable import ContainerPrimer

@Suite struct PortWatcherTests {
  /// Returns canned `/proc/net/tcp` text, simulating a service that only starts
  /// listening after the first poll.
  private final class StubRunner: GuestCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let table: String

    init(table: String) { self.table = table }

    func run(_ arguments: [String]) async throws -> String {
      lock.withLock {
        calls += 1
        return calls == 1 ? "" : table
      }
    }
  }

  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ message: String) {
      lock.withLock { storage.append(message) }
    }
    var messages: [String] {
      lock.withLock { storage }
    }
    var count: Int {
      lock.withLock { storage.count }
    }
  }

  @Test func reportsEachPortOnceWithReachabilityLabels() async throws {
    // 0.0.0.0:8080 (reachable) and 127.0.0.1:5432 (loopback), both LISTEN.
    let table = """
         0: 00000000:1F90 00000000:0000 0A 0 0 0 1
         1: 0100007F:1538 00000000:0000 0A 0 0 0 1
      """
    let collector = Collector()
    let watcher = PortWatcher(
      runner: StubRunner(table: table),
      ipv4Address: "10.0.0.2",
      pollInterval: .milliseconds(1),
      report: { collector.add($0) }
    )

    let task = Task { await watcher.watch() }
    // Wait for both ports to be reported (across several polls), then stop.
    for _ in 0..<500 where collector.count < 2 {
      try await Task.sleep(for: .milliseconds(2))
    }
    task.cancel()
    _ = await task.value

    let messages = collector.messages
    #expect(messages.count == 2)  // each port reported exactly once
    #expect(messages.contains("[port-listener] listening on http://10.0.0.2:8080"))
    #expect(
      messages.contains(
        "[port-listener] warning: port 5432 is listening on loopback only — not reachable from the host"
      ))
  }
}
