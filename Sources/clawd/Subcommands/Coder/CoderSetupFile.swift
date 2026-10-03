import ArgumentParser
import ClawSecrets
import Foundation

/// Edits literal env assignments without executing the configuration or displaying its secrets.
struct CoderSetupFile {
  let url: URL
  let values: [String: String]

  private let original: Data
  private let lines: [String]
  private let keys: [String?]

  init(path: String) throws {
    url = URL(fileURLWithPath: path).resolvingSymlinksInPath()

    guard let data = FileManager.default.contents(atPath: url.path),
          let contents = String(data: data, encoding: .utf8)
    else {
      throw ValidationError(
        "Cannot read the existing env file. Configure clawd first or use --env-file."
      )
    }

    original = data
    lines = contents.components(separatedBy: "\n")

    var values: [String: String] = [:]
    var keys: [String?] = []

    for (index, line) in lines.enumerated() {
      do {
        let assignment = try Self.parse(line)
        keys.append(assignment?.key)

        if let assignment {
          values[assignment.key] = assignment.value
        }
      } catch {
        throw ValidationError(
          """
          Env file line \(index + 1) is not a literal assignment. \
          Setup accepts one KEY=value per line with optional quotes; shell expressions \
          and multiline values require manual configuration. The file was not changed.
          """
        )
      }
    }

    self.values = values
    self.keys = keys
  }

  func save(_ updates: [String: String]) throws -> Bool {
    var remaining = updates
    var output: [String] = []

    for (line, key) in zip(lines, keys) {
      guard let key, updates[key] != nil else {
        output.append(line)
        continue
      }

      if let value = remaining.removeValue(forKey: key) {
        output.append(Self.assignment(key, value))
      }
    }

    var contents = output.joined(separator: "\n")
    if !contents.hasSuffix("\n") {
      contents += "\n"
    }
    if !remaining.isEmpty {
      contents += Self.assignments(remaining) + "\n"
    }

    let currentContents = FileManager.default.contents(atPath: url.path)
    guard currentContents == original else {
      throw ValidationError(
        "The env file changed during setup. Rerun setup to preserve those edits."
      )
    }

    let outcome = try SecureFilePublisher().publish(Data(contents.utf8), to: url, mode: .replace)

    if case .commitUncertain = outcome {
      return false
    }

    return true
  }

  static func assignments(_ values: [String: String]) -> String {
    values.keys
      .sorted()
      .map { key in
        assignment(key, values[key] ?? "")
      }
      .joined(separator: "\n")
  }
}

// MARK: - Literal Assignments

private extension CoderSetupFile {
  enum ParseError: Error {
    case unsupported
  }

  static func assignment(_ key: String, _ value: String) -> String {
    let escaped = value.reduce(into: "") { result, character in
      if "\\\"$`".contains(character) {
        result.append("\\")
      }
      result.append(character)
    }
    return "\(key)=\"\(escaped)\""
  }

  static func parse(_ line: String) throws -> (key: String, value: String)? {
    var text = line.trimmingCharacters(in: .whitespacesAndNewlines)

    if text.isEmpty || text.hasPrefix("#") {
      return nil
    }

    if text.hasPrefix("export ") {
      text = String(text.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
    }

    guard let assignmentSeparator = text.firstIndex(of: "=") else {
      throw ParseError.unsupported
    }

    let key = String(text[..<assignmentSeparator])
    guard let firstCharacter = key.first,
          firstCharacter.isASCII,
          firstCharacter.isLetter || firstCharacter == "_"
    else {
      throw ParseError.unsupported
    }

    let hasValidKeyCharacters = key.allSatisfy { character in
      character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
    guard hasValidKeyCharacters else {
      throw ParseError.unsupported
    }

    let rawValue = String(text[text.index(after: assignmentSeparator)...])
    return (key, try literal(rawValue))
  }

  static func literal(_ raw: String) throws -> String {
    var input = raw[...]
    let quote: Character? =
      if input.first == "'" || input.first == "\"" {
        input.removeFirst()
      } else {
        nil
      }
    var value = ""

    while let character = input.first {
      input.removeFirst()

      if character == quote {
        try requireComment(input)
        return value
      }

      if quote == nil && character.isWhitespace {
        try requireComment(input, separated: true)
        return value
      }

      if quote != "'" && character == "\\" {
        guard let escaped = input.first else {
          throw ParseError.unsupported
        }

        input.removeFirst()
        if quote == "\"" && !"\\\"$`".contains(escaped) {
          value.append("\\")
        }
        value.append(escaped)
      } else {
        if quote != "'" && "$`".contains(character) {
          throw ParseError.unsupported
        }

        if quote == nil && "'\";&|<>()".contains(character) {
          throw ParseError.unsupported
        }

        value.append(character)
      }
    }

    guard quote == nil else {
      throw ParseError.unsupported
    }

    return value
  }

  static func requireComment(_ remainder: Substring, separated: Bool = false) throws {
    guard separated || remainder.isEmpty || remainder.first?.isWhitespace == true else {
      throw ParseError.unsupported
    }

    let suffix = remainder.trimmingCharacters(in: .whitespaces)

    guard suffix.isEmpty || suffix.hasPrefix("#") else {
      throw ParseError.unsupported
    }
  }
}
