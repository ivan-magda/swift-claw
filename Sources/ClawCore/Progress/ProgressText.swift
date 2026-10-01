import Foundation

/// Emits safe spans and holds only a trailing proper prefix of a known exact secret.
public struct StreamingSecretRedactor: Sendable {
  private let secrets: [[UInt8]]
  private var carry: [UInt8] = []

  public init(secretValues: [String]) {
    secrets = secretValues.filter {
      !$0.isEmpty
    }.map {
      Array($0.utf8)
    }.sorted {
      $0.count > $1.count
    }
  }

  public mutating func append(_ text: String) -> String {
    let input = carry + text.utf8
    carry.removeAll(keepingCapacity: true)

    var output: [UInt8] = []
    var offset = 0

    while offset < input.count {
      let remaining = input[offset...]

      if secrets.contains(where: { secret in
        remaining.count < secret.count && secret.starts(with: remaining)
      }) {
        carry = Array(remaining)
        break
      }

      if let secret = secrets.first(where: {
        remaining.starts(with: $0)
      }) {
        output.append(contentsOf: SecretRedactor.replacement.utf8)
        offset += secret.count
      } else {
        output.append(input[offset])
        offset += 1
      }
    }

    return String(decoding: output, as: UTF8.self)
  }

  public mutating func finish() -> String {
    // A shorter complete secret may also be a prefix of a longer one.
    let suffix = String(decoding: carry, as: UTF8.self)
    carry.removeAll(keepingCapacity: true)
    let values = secrets.map {
      String(decoding: $0, as: UTF8.self)
    }
    return SecretRedactor(secretValues: values).redact(suffix)
  }
}

public enum ProgressText {
  public static func preview(_ text: String, secretValues: [String], limit: Int) -> String {
    let safe = SecretRedactor(secretValues: secretValues).redact(text)
    return String(normalize(safe).trimmingCharacters(in: .whitespaces).prefix(max(0, limit)))
  }

  /// Keeps one trailing space so separately appended safe spans cannot lose word boundaries.
  package static func normalize(_ text: String) -> String {
    var result = ""
    var hasSpace = false

    for scalar in text.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        if !result.isEmpty && !hasSpace {
          result.append(" ")
          hasSpace = true
        }
        continue
      }

      let category = scalar.properties.generalCategory
      if category == .control || (category == .format && scalar.value != 0x200D) {
        continue
      }

      result.unicodeScalars.append(scalar)
      hasSpace = false
    }

    return result
  }
}
