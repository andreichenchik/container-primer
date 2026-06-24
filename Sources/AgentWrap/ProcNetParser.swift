/// A TCP socket the container is listening on, discovered from `/proc/net/tcp`.
struct ListeningPort: Hashable {
  /// Which addresses the socket is bound to, which determines host reachability.
  enum Scope {
    /// Bound to all interfaces (`0.0.0.0` / `::`) — reachable from the host.
    case allInterfaces
    /// Bound to loopback (`127.0.0.1` / `::1`) — not reachable from the host.
    case loopback
    /// Bound to a specific non-loopback address — assumed reachable.
    case other
  }

  let port: UInt16
  let scope: Scope
}

/// Parses the contents of `/proc/net/tcp` and `/proc/net/tcp6` into the set of
/// TCP sockets in the LISTEN state.
enum ProcNetParser {
  /// Linux TCP state for a listening socket (`TCP_LISTEN`).
  private static let listenState = "0A"

  /// Extracts listening sockets from one or more concatenated `/proc/net/tcp`
  /// payloads (IPv4 and IPv6 rows may be mixed; non-row lines are ignored).
  static func parse(_ text: String) -> Set<ListeningPort> {
    var result: Set<ListeningPort> = []
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      // Expect at least: sl, local_address, rem_address, st, ...
      guard fields.count >= 4, fields[3] == listenState else { continue }
      let local = fields[1].split(separator: ":")
      guard local.count == 2,
        let port = UInt16(local[1], radix: 16)
      else { continue }
      result.insert(ListeningPort(port: port, scope: scope(forHexAddress: local[0])))
    }
    return result
  }

  /// Classifies the hex local address. `/proc/net/tcp` stores the IPv4 address
  /// as 8 hex chars and IPv6 as 32; "all zeros" means bound to all interfaces,
  /// and the loopback addresses are well-known constants.
  private static func scope(forHexAddress hex: Substring) -> ListeningPort.Scope {
    let upper = hex.uppercased()
    if upper.allSatisfy({ $0 == "0" }) { return .allInterfaces }
    switch upper {
    case "0100007F":  // 127.0.0.1 (little-endian)
      return .loopback
    case "00000000000000000000000001000000":  // ::1
      return .loopback
    default:
      return .other
    }
  }
}
