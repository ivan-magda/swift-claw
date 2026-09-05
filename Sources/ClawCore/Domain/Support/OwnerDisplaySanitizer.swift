/// Makes control and formatting scalars visible before model-authored text reaches an owner-facing
/// approval or execution notice. The original text remains unchanged for validation and execution.
public enum OwnerDisplaySanitizer {
  public static func renderUnsafeScalars(in text: String) -> String {
    render(in: text, renderingBackticks: false)
  }

  /// Also makes Markdown fence delimiters visible, so model-authored text cannot escape the
  /// gateway's code fence and become owner-visible formatting.
  public static func renderMarkdownCodeFenceContent(in text: String) -> String {
    render(in: text, renderingBackticks: true)
  }
}

// MARK: - Rendering

private extension OwnerDisplaySanitizer {
  static func render(in text: String, renderingBackticks: Bool) -> String {
    var rendered = ""
    rendered.reserveCapacity(text.count)

    for scalar in text.unicodeScalars {
      if isUnsafeForDisplay(scalar) || (renderingBackticks && scalar.value == 0x60) {
        rendered.append(visibleScalarCode(for: scalar))
      } else {
        rendered.unicodeScalars.append(scalar)
      }
    }

    return rendered
  }
}

// MARK: - Scalar Classification

private extension OwnerDisplaySanitizer {
  static func isUnsafeForDisplay(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control:
      // Preserve ordinary multiline command layout and indentation. Other C0/C1 controls can
      // overwrite or repaint owner-visible text and therefore render as explicit scalar codes.
      return scalar.value != 0x09 && scalar.value != 0x0A
    case .format, .lineSeparator, .paragraphSeparator:
      return true
    default:
      return false
    }
  }

  static func visibleScalarCode(for scalar: Unicode.Scalar) -> String {
    let hex = String(scalar.value, radix: 16, uppercase: true)
    let paddedHex = String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    return "<U+\(paddedHex)>"
  }
}
