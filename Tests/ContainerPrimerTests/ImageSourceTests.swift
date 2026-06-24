import Foundation
import Testing

@testable import ContainerPrimer

@Suite struct ImageSourceTests {
  private func metadata(cacheKey: String) -> RootfsMetadata {
    RootfsMetadata(
      cacheKey: cacheKey,
      imageReference: "registry/image:tag",
      imageDigest: "sha256:abc",
      rootfsSizeInBytes: 4096,
      diskSizeInBytes: 8_589_934_592,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  @Test func registryCacheValidWhenKeyMatches() throws {
    let source = RegistryImageSource(reference: "docker.io/library/nginx:latest")
    #expect(try source.isCacheValid(metadata(cacheKey: source.cacheKey)))
  }

  @Test func registryCacheInvalidForDifferentReference() throws {
    let source = RegistryImageSource(reference: "docker.io/library/nginx:latest")
    let other = RegistryImageSource(reference: "docker.io/library/redis:latest")
    #expect(try !source.isCacheValid(metadata(cacheKey: other.cacheKey)))
  }

  @Test func buildCacheValidWhenContextUnchanged() throws {
    let context = try TempContext()
    defer { context.cleanup() }
    let source = context.source()
    #expect(try source.isCacheValid(metadata(cacheKey: source.cacheKey)))
  }

  @Test func buildCacheInvalidAfterEditingContext() throws {
    let context = try TempContext()
    defer { context.cleanup() }
    let before = try context.source().cacheKey

    context.write("server.ts", "console.log('changed')")
    #expect(try context.source().cacheKey != before)
  }

  @Test func buildAndRegistryKeysDiffer() throws {
    let context = try TempContext()
    defer { context.cleanup() }
    let registry = RegistryImageSource(reference: "x").cacheKey
    #expect(try context.source().cacheKey != registry)
  }
}

/// A throwaway build context directory for cache-key tests.
private struct TempContext {
  let dir: URL

  init() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ctx-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    write("Containerfile", "FROM scratch")
    write("server.ts", "console.log('hi')")
  }

  func write(_ name: String, _ contents: String) {
    try? contents.write(
      to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  func source() -> BuildImageSource {
    BuildImageSource(contextDir: dir, containerfile: dir.appendingPathComponent("Containerfile"))
  }

  func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
