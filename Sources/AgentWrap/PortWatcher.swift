import Containerization
import Foundation

/// Runs a command inside a running container and returns its stdout. Abstracts
/// the container exec API so the watcher can be tested without a real VM.
protocol GuestCommandRunner: Sendable {
  func run(_ arguments: [String]) async throws -> String
}

/// Polls a running container for the TCP ports it is listening on and reports
/// each newly-discovered port once, as a clickable URL. Reachable ports are
/// surfaced as `http://<ip>:<port>`; loopback-only binds are flagged because
/// they cannot be reached from the host.
///
/// Detection reads `/proc/net/tcp` from inside the guest, so it sees the actual
/// listeners regardless of which port the image's service chooses.
struct PortWatcher {
  private let runner: GuestCommandRunner
  private let ipv4Address: String
  private let pollInterval: Duration
  private let report: @Sendable (String) -> Void

  /// Prefix on every line so the watcher's output stands out from the
  /// container's own logs.
  static let logPrefix = "[port-listener]"

  init(
    runner: GuestCommandRunner,
    ipv4Address: String,
    pollInterval: Duration = .seconds(1),
    report: @escaping @Sendable (String) -> Void = { print($0) }
  ) {
    self.runner = runner
    self.ipv4Address = ipv4Address
    self.pollInterval = pollInterval
    self.report = report
  }

  /// Polls until the surrounding task is cancelled, reporting new ports as they
  /// appear. Per-tick failures (service or shell not ready yet) are ignored so
  /// the watcher keeps trying.
  func watch() async {
    var seen: Set<ListeningPort> = []
    while !Task.isCancelled {
      if let text = try? await runner.run(probeCommand) {
        for port in ProcNetParser.parse(text).subtracting(seen).sorted(by: { $0.port < $1.port }) {
          seen.insert(port)
          report(message(for: port))
        }
      }
      try? await Task.sleep(for: pollInterval)
    }
  }

  /// Reads both the IPv4 and IPv6 listener tables; `2>/dev/null` keeps it quiet
  /// if a kernel lacks IPv6.
  private var probeCommand: [String] {
    ["sh", "-c", "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"]
  }

  private func message(for port: ListeningPort) -> String {
    switch port.scope {
    case .allInterfaces, .other:
      return "\(Self.logPrefix) listening on http://\(ipv4Address):\(port.port)"
    case .loopback:
      return
        "\(Self.logPrefix) warning: port \(port.port) is listening on loopback only — not reachable from the host"
    }
  }
}

/// Drives `PortWatcher` against a live container via the Containerization exec API.
struct ContainerCommandRunner: GuestCommandRunner {
  let container: LinuxContainer

  func run(_ arguments: [String]) async throws -> String {
    let output = BufferWriter()
    let process = try await container.exec(UUID().uuidString) { config in
      config.arguments = arguments
      config.stdout = output
    }
    try await process.start()
    _ = try await process.wait()
    try? await process.delete()
    return output.text
  }
}
