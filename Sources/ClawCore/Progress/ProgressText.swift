import Foundation

/// Emits safe spans and holds only a trailing proper prefix of a known exact secret.
public struct StreamingSecretRedactor: Sendable {
  private let secrets: [[UInt8]]
  private var carry: [UInt8] = []
  private var preservesRedactionTokens = false

  public init(secretValues: [String]) {
    secrets = secretValues.filter {
      !$0.isEmpty
    }.map {
      Array($0.utf8)
    }.sorted {
      $0.count > $1.count
    }
  }

  package init(secretValues: [String], preservingRedactionTokens: Bool) {
    self.init(secretValues: secretValues)
    preservesRedactionTokens = preservingRedactionTokens
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
      } else if preservesRedactionTokens && remaining.starts(with: SecretRedactor.replacement.utf8)
      {
        output.append(contentsOf: SecretRedactor.replacement.utf8)
        offset += SecretRedactor.replacement.utf8.count
      } else {
        output.append(input[offset])
        offset += 1
      }
    }

    return String(bytes: output, encoding: .utf8) ?? ""
  }

  public mutating func finish() -> String {
    // A shorter complete secret may also be a prefix of a longer one.
    let suffix = String(bytes: carry, encoding: .utf8) ?? ""
    carry.removeAll(keepingCapacity: true)
    let values = secrets.compactMap {
      String(bytes: $0, encoding: .utf8)
    }
    return SecretRedactor(secretValues: values).redact(suffix)
  }
}

/// Redacts original and normalized display spans without accumulating an explanation.
public struct StreamingProgressText: Sendable {
  private var originalRedactor: StreamingSecretRedactor
  private var normalizedRedactor: StreamingSecretRedactor
  private var hasNormalizedText = false
  private var hasNormalizedSpace = false

  public init(secretValues: [String]) {
    originalRedactor = StreamingSecretRedactor(secretValues: secretValues)
    let normalizedSecrets = secretValues.map {
      ProgressText.normalize($0).trimmingCharacters(in: .whitespaces)
    }
    normalizedRedactor = StreamingSecretRedactor(
      secretValues: normalizedSecrets,
      preservingRedactionTokens: true
    )
  }

  public mutating func append(_ text: String) -> String {
    appendSafe(originalRedactor.append(text))
  }

  public mutating func finish() -> String {
    appendSafe(originalRedactor.finish()) + normalizedRedactor.finish()
  }
}

// MARK: - Incremental Display Normalization

private extension StreamingProgressText {
  mutating func appendSafe(_ safe: String) -> String {
    let normalized = ProgressText.normalize(
      safe,
      startsAfterText: hasNormalizedText,
      startsAfterSpace: hasNormalizedSpace
    )

    if !normalized.isEmpty {
      hasNormalizedText = true
      hasNormalizedSpace = normalized.last == " "
    }

    return normalizedRedactor.append(normalized)
  }
}

public enum ProgressText {
  /// Identifies a page without credentials, query or fragment. Redaction precedes middle elision
  /// so shortening a long path cannot expose a partial secret from its final segment.
  public static func webPagePreview(_ url: URLComponents, secretValues: [String]) -> String? {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty
    else {
      return nil
    }

    let limit = TurnProgressLimits.previewCharacters
    let safe = preview(host + url.path, secretValues: secretValues, limit: .max)
    guard safe.count > limit else {
      return safe
    }
    let segments = safe.split(separator: "/", omittingEmptySubsequences: true)
    guard let safeHost = segments.first, let leaf = segments.last, segments.count > 1,
          safeHost.count + 3 < limit
    else {
      return String(safe.prefix(limit - 1)) + "…"
    }

    let prefix = String(safeHost) + "/…/"
    return prefix + leaf.suffix(limit - prefix.count)
  }

  public static func preview(_ text: String, secretValues: [String], limit: Int) -> String {
    var originalRedactor = StreamingSecretRedactor(
      secretValues: secretValues,
      preservingRedactionTokens: true
    )
    let safe = originalRedactor.append(text) + originalRedactor.finish()
    let normalized = normalize(safe).trimmingCharacters(in: .whitespaces)
    let normalizedSecrets = secretValues.map {
      normalize($0).trimmingCharacters(in: .whitespaces)
    }
    var displayRedactor = StreamingSecretRedactor(
      secretValues: normalizedSecrets,
      preservingRedactionTokens: true
    )
    let displaySafe = displayRedactor.append(normalized) + displayRedactor.finish()
    return String(displaySafe.prefix(max(0, limit)))
  }

  /// Keeps one trailing space so separately appended safe spans cannot lose word boundaries.
  package static func normalize(
    _ text: String,
    startsAfterText: Bool = false,
    startsAfterSpace: Bool = false
  ) -> String {
    var result = ""
    var hasSpace = startsAfterSpace

    for scalar in text.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        if (!result.isEmpty || startsAfterText) && !hasSpace {
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
