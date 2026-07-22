/// Blanks the values of sealed secret assignments in an env file's text, leaving every other
/// byte untouched, so plaintext secrets leave the disk without hand-editing a working config.
enum EnvFileSecretScrubber {
  static func scrub(
    contents: String,
    keys: [String]
  ) -> (contents: String, scrubbedKeys: [String]) {
    var scrubbedKeys: [String] = []
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)

    let rewritten = lines.map { line in
      scrubLine(String(line), keys: keys, scrubbedKeys: &scrubbedKeys)
    }

    return (rewritten.joined(separator: "\n"), scrubbedKeys)
  }
}

// MARK: - Line Rewriting

private extension EnvFileSecretScrubber {
  static func scrubLine(
    _ line: String,
    keys: [String],
    scrubbedKeys: inout [String]
  ) -> String {
    for key in keys {
      guard let prefix = assignmentPrefix(of: line, key: key) else {
        continue
      }

      guard line.count > prefix.count else {
        continue
      }

      scrubbedKeys.append(key)
      return prefix
    }

    return line
  }

  /// Everything up to and including the `=` when the line assigns `key` (optionally
  /// indented and/or `export`-prefixed), else nil.
  static func assignmentPrefix(of line: String, key: String) -> String? {
    var head = Substring(line)
    let indent = head.prefix(while: { $0 == " " || $0 == "\t" })

    head = head.dropFirst(indent.count)
    var exportPrefix = ""

    if head.hasPrefix("export ") {
      exportPrefix = "export "
      head = head.dropFirst(exportPrefix.count)
    }

    guard head.hasPrefix("\(key)=") else {
      return nil
    }

    return String(indent) + exportPrefix + key + "="
  }
}
