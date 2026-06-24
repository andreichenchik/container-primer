import Testing

@testable import AgentWrap

@Suite struct ProcNetParserTests {
  /// A realistic `/proc/net/tcp` header line; the parser must skip it.
  private let header =
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"

  @Test func findsListenerOnAllInterfaces() {
    // 0.0.0.0:8080 (1F90) in LISTEN (0A).
    let text = """
      \(header)
         0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1234 1
      """
    let ports = ProcNetParser.parse(text)
    #expect(ports == [ListeningPort(port: 8080, scope: .allInterfaces)])
  }

  @Test func classifiesLoopbackBind() {
    // 127.0.0.1:1538 (5432) LISTEN.
    let text = """
      \(header)
         0: 0100007F:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1
      """
    let ports = ProcNetParser.parse(text)
    #expect(ports == [ListeningPort(port: 5432, scope: .loopback)])
  }

  @Test func ignoresNonListeningSockets() {
    // ESTABLISHED (01) and TIME_WAIT (06) must be ignored.
    let text = """
      \(header)
         0: 00000000:1F90 0100007F:9A3C 01 00000000:00000000 00:00000000 00000000     0        0 1 1
         1: 00000000:0050 0100007F:9A3D 06 00000000:00000000 00:00000000 00000000     0        0 0 1
      """
    #expect(ProcNetParser.parse(text).isEmpty)
  }

  @Test func parsesIPv6AllInterfacesAndLoopback() {
    // [::]:1F90 all-interfaces and [::1]:1F91 loopback, both LISTEN.
    let text = """
      \(header)
         0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 0 0 0 1
         1: 00000000000000000000000001000000:1F91 00000000000000000000000000000000:0000 0A 0 0 0 1
      """
    let ports = ProcNetParser.parse(text)
    #expect(
      ports == [
        ListeningPort(port: 8080, scope: .allInterfaces),
        ListeningPort(port: 8081, scope: .loopback),
      ])
  }

  @Test func returnsEmptyForBlankInput() {
    #expect(ProcNetParser.parse("").isEmpty)
    #expect(ProcNetParser.parse(header).isEmpty)
  }
}
