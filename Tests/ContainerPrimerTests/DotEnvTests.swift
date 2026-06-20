import Testing

@testable import ContainerPrimer

@Suite struct DotEnvTests {
  @Test func parsesSimplePairs() {
    let pairs = DotEnv.parse("FOO=bar\nBAZ=qux")
    #expect(pairs.count == 2)
    #expect(pairs[0] == ("FOO", "bar"))
    #expect(pairs[1] == ("BAZ", "qux"))
  }

  @Test func skipsCommentsAndBlankLines() {
    let pairs = DotEnv.parse("# a comment\n\n   \nFOO=bar\n# trailing")
    #expect(pairs.map(\.key) == ["FOO"])
  }

  @Test func dropsExportPrefix() {
    let pairs = DotEnv.parse("export FOO=bar")
    #expect(pairs.count == 1)
    #expect(pairs[0] == ("FOO", "bar"))
  }

  @Test func stripsMatchingQuotes() {
    let pairs = DotEnv.parse(#"A="double"\#nB='single'"#)
    #expect(pairs[0] == ("A", "double"))
    #expect(pairs[1] == ("B", "single"))
  }

  @Test func keepsMismatchedQuotes() {
    let pairs = DotEnv.parse("A=\"unbalanced")
    #expect(pairs[0] == ("A", "\"unbalanced"))
  }

  @Test func trimsSurroundingWhitespace() {
    let pairs = DotEnv.parse("  FOO  =  bar  ")
    #expect(pairs[0] == ("FOO", "bar"))
  }

  @Test func ignoresLinesWithoutEquals() {
    let pairs = DotEnv.parse("NOEQUALS\nFOO=bar")
    #expect(pairs.map(\.key) == ["FOO"])
  }

  @Test func ignoresEmptyKey() {
    let pairs = DotEnv.parse("=value\nFOO=bar")
    #expect(pairs.map(\.key) == ["FOO"])
  }

  @Test func keepsEqualsInValue() {
    let pairs = DotEnv.parse("URL=https://host/path?a=b")
    #expect(pairs[0] == ("URL", "https://host/path?a=b"))
  }
}
