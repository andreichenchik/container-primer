import Darwin
import Foundation

/// Loads `KEY=VALUE` pairs from a `.env` file into the process environment.
/// The set of keys it declares is the launcher's contract for which variables
/// to forward into the container.
enum DotEnv {
  /// Parse `.env` file contents into key/value pairs. Skips blank lines and
  /// `#` comments, drops an optional `export ` prefix, trims surrounding
  /// whitespace, and strips matching single or double quotes around values.
  /// Lines without `=` or with an empty key are ignored.
  static func parse(_ contents: String) -> [(key: String, value: String)] {
    var pairs: [(key: String, value: String)] = []
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("export ") { line.removeFirst("export ".count) }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value = String(value.dropFirst().dropLast())
      }
      if key.isEmpty { continue }
      pairs.append((key, value))
    }
    return pairs
  }

  /// Load the `.env` file from `directory` into the process environment and
  /// return the keys it declared. Existing environment variables take
  /// precedence, so the shell can still override `.env`. A missing file is a
  /// no-op returning an empty list.
  @discardableResult
  static func load(
    from directory: String = FileManager.default.currentDirectoryPath
  ) -> [String] {
    let path = directory + "/.env"
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var keys: [String] = []
    for (key, value) in parse(contents) {
      setenv(key, value, 0)
      keys.append(key)
    }
    return keys
  }
}
