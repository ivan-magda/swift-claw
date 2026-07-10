import Foundation

public enum MemoryWriteWarning: Sendable, Equatable {
  case possibleSecret
  case possibleInstruction

  public var confirmationSummary: String {
    switch self {
    case .possibleSecret:
      "possible secret-shaped text"
    case .possibleInstruction:
      "possible instruction-shaped text"
    }
  }
}

public enum MemoryWriteBuildError: Error, Sendable, Equatable {
  case emptyAfterNormalization
}

public struct MemoryWriteRequest: Sendable, Equatable {
  public let item: NewMemoryItem
  public let confirmationText: String
  public let warnings: [MemoryWriteWarning]

  public init(
    item: NewMemoryItem,
    confirmationText: String,
    warnings: [MemoryWriteWarning]
  ) {
    self.item = item
    self.confirmationText = confirmationText
    self.warnings = warnings
  }
}

public enum MemoryWriteBuilder {
  public static func build(
    rawText: String,
    kind: MemoryKind,
    sessionId: Int64?,
    source: MemorySource = .owner,
    importance: Importance = .normal,
    sensitivity: Sensitivity = .normal
  ) throws -> MemoryWriteRequest {
    let normalizedText = (rawText as NSString).precomposedStringWithCanonicalMapping
    let storedText = stripBlockedControls(from: normalizedText).trimmingCharacters(
      in: .whitespacesAndNewlines
    )

    guard storedText.isEmpty == false else {
      throw MemoryWriteBuildError.emptyAfterNormalization
    }

    let warnings = scanWarnings(in: storedText)
    let item = NewMemoryItem(
      text: storedText,
      kind: kind,
      sensitivity: sensitivity,
      importance: importance,
      source: source,
      sessionId: sessionId
    )

    let visibleText = renderVisibleControls(in: normalizedText).trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    var lines = [
      "Remember as \(kind.rawValue):",
      visibleText,
    ]

    if warnings.isEmpty == false {
      let summaries = warnings.map(\.confirmationSummary).joined(separator: ", ")
      lines.append("Warnings: \(summaries)")
    }

    lines.append("Reply yes to save, no to cancel.")

    return MemoryWriteRequest(
      item: item,
      confirmationText: lines.joined(separator: "\n"),
      warnings: warnings
    )
  }
}

// MARK: - Warning Scanning

private extension MemoryWriteBuilder {
  static func scanWarnings(in text: String) -> [MemoryWriteWarning] {
    let loweredText = text.lowercased()
    var warnings: [MemoryWriteWarning] = []

    let secretWarningPatterns: Set<String> = ["sk-", "api_key", "token"]
    if secretWarningPatterns.contains(where: { loweredText.contains($0) }) {
      warnings.append(.possibleSecret)
    }

    let instructionWarningPatterns: Set<String> = ["ignore previous", "system prompt"]
    if instructionWarningPatterns.contains(where: { loweredText.contains($0) }) {
      warnings.append(.possibleInstruction)
    }

    return warnings
  }
}

// MARK: - Control Character Sanitization

private extension MemoryWriteBuilder {
  static func stripBlockedControls(from text: String) -> String {
    String(text.unicodeScalars.filter { blockedControls.contains($0.value) == false })
  }

  static func renderVisibleControls(in text: String) -> String {
    var rendered = ""
    rendered.reserveCapacity(text.count)

    for scalar in text.unicodeScalars {
      if blockedControls.contains(scalar.value) {
        rendered.append(visibleScalarCode(for: scalar))
      } else {
        rendered.unicodeScalars.append(scalar)
      }
    }

    return rendered
  }

  static func visibleScalarCode(for scalar: Unicode.Scalar) -> String {
    let hex = String(scalar.value, radix: 16, uppercase: true)
    let paddedHex = String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    return "<U+\(paddedHex)>"
  }

  static let blockedControls: Set<UInt32> = {
    var scalars: Set<UInt32> = [
      0x061C,
      0x200B,
      0x200C,
      0x200D,
      0x200E,
      0x200F,
      0x2060,
      0xFEFF,
    ]

    for value in 0x202A...0x202E {
      scalars.insert(UInt32(value))
    }

    for value in 0x2066...0x2069 {
      scalars.insert(UInt32(value))
    }

    return scalars
  }()
}
