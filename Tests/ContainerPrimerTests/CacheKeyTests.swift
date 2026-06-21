import Testing

@testable import ContainerPrimer

@Suite struct CacheKeyTests {
  @Test func hashingIsDeterministic() {
    #expect(CacheKey.hashing("hello") == CacheKey.hashing("hello"))
  }

  @Test func hashingDistinguishesInputs() {
    #expect(CacheKey.hashing("a") != CacheKey.hashing("b"))
  }

  @Test func hashingIsSha256Hex() {
    let key = CacheKey.hashing("hello")
    #expect(key.count == 64)
    #expect(key.allSatisfy { $0.isHexDigit })
  }
}
