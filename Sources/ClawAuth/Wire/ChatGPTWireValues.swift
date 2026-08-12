import ClawCore
import Foundation

/// Bounds and sanitizers for values that arrive from the vendor. Every field the device flow reads
/// off the wire passes through one of these before it reaches a header, a terminal, or an owner's
/// chat, so a hostile or merely broken response cannot widen what the daemon emits.
package enum ChatGPTWireValues {
  /// A whole, strictly positive count encoded as either a JSON number or an ASCII decimal string —
  /// the two encodings the vendor is observed to use interchangeably for `interval` and
  /// `expires_in`. Everything else, including a zero or fractional interval that would spin the
  /// poll loop, is rejected rather than coerced.
  static func positiveInteger(_ value: JSONValue) -> Int? {
    switch value {
    case .integer(let integer):
      return integer > 0 && integer < Int.max ? integer : nil
    case .number(let number):
      return positiveInteger(fromNumber: number)
    case .string(let text):
      return positiveInteger(fromDecimalString: text)
    case .null, .bool, .array, .object:
      return nil
    }
  }

  /// A value fit to become an HTTP header: bounded, ASCII, and free of the whitespace and controls
  /// that would let a remote value fold in a header of its own. Returns the value unchanged, so a
  /// caller cannot accidentally use an unvalidated original.
  static func headerSafeToken(_ raw: String, maxBytes: Int) -> String? {
    guard withinBounds(raw, maxBytes: maxBytes) else {
      return nil
    }
    let isSafe = raw.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII && isControl(scalar) == false && isWhitespace(scalar) == false
    }
    return isSafe ? raw : nil
  }

  /// A value fit to be shown or carried as data: bounded and control-free, but allowed the spaces
  /// and non-ASCII text a printed user code may legitimately contain.
  static func controlFree(_ raw: String, maxBytes: Int) -> String? {
    guard withinBounds(raw, maxBytes: maxBytes) else {
      return nil
    }
    let isSafe = raw.unicodeScalars.allSatisfy { scalar in
      isControl(scalar) == false
    }
    return isSafe ? raw : nil
  }

  /// Renders vendor-supplied text safe to put in front of an owner. Remote text reaching stderr or
  /// Telegram is untrusted: it may repaint or retitle a terminal, and it may quote a secret back.
  ///
  /// Order is load-bearing. Sanitizing precedes redaction so that text which only *becomes* a
  /// secret once its escapes are stripped is still matched, and truncation comes last so it can
  /// only ever cut a placeholder rather than expose the prefix of a token that outran the bound.
  package static func safeRemoteDiagnostic(
    _ raw: String,
    redacting values: [String],
    maxBytes: Int
  ) -> String {
    let sanitized = collapsingWhitespace(strippingControls(strippingEscapeSequences(raw)))
    let redacted = SecretRedactor(secretValues: values).redact(sanitized)
    return truncating(redacted, toBytes: maxBytes)
  }
}

// MARK: - Bounds

private extension ChatGPTWireValues {
  /// Measures the cap in UTF-8 bytes, which is what a wire format and an HTTP header count. A
  /// character count would admit a value several times its stated size.
  static func withinBounds(_ raw: String, maxBytes: Int) -> Bool {
    raw.isEmpty == false && raw.utf8.count <= maxBytes
  }

  static func truncating(_ text: String, toBytes maxBytes: Int) -> String {
    guard text.utf8.count > maxBytes else {
      return text
    }
    var truncated = String.UnicodeScalarView()
    var used = 0
    for scalar in text.unicodeScalars {
      let width = String(scalar).utf8.count
      guard used + width <= maxBytes else {
        break
      }
      truncated.append(scalar)
      used += width
    }
    return String(truncated)
  }
}

// MARK: - Scalar Classes

private extension ChatGPTWireValues {
  /// Covers C0 and C1 alike. A C1 control is invisible, is not ASCII, and — at 0x9B — introduces a
  /// terminal control sequence without an ESC byte anywhere in the text.
  static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
  }

  static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace
  }

  static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar)
  }
}

// MARK: - Positive Integer Parsing

private extension ChatGPTWireValues {
  static func positiveInteger(fromNumber number: Double) -> Int? {
    guard
      number.isFinite,
      number > 0,
      number.rounded(.towardZero) == number,
      number < Double(Int.max)
    else {
      return nil
    }
    return Int(number)
  }

  /// ASCII decimal digits only. `Int(_:)` alone would accept a leading sign and non-ASCII digit
  /// shapes, neither of which the vendor sends and both of which read as an attempt to be clever.
  static func positiveInteger(fromDecimalString text: String) -> Int? {
    guard
      text.isEmpty == false,
      text.unicodeScalars.allSatisfy(isASCIIDigit),
      let parsed = Int(text),
      parsed > 0
    else {
      return nil
    }
    return parsed
  }
}

// MARK: - Terminal Sanitizing

private extension ChatGPTWireValues {
  static let escape: Unicode.Scalar = "\u{1B}"
  static let controlSequenceIntroducer: Unicode.Scalar = "\u{9B}"
  static let bell: Unicode.Scalar = "\u{7}"

  /// Removes ANSI escape sequences whole, rather than deleting the ESC byte and leaving its
  /// parameters as text. Handles the ESC-introduced and C1 forms of CSI, OSC strings terminated by
  /// either BEL or ST, and the two-character escapes.
  static func strippingEscapeSequences(_ raw: String) -> String {
    var output = String.UnicodeScalarView()
    var scalars = Array(raw.unicodeScalars)[...]

    while let scalar = scalars.first {
      if scalar == escape {
        scalars = scalars.dropFirst()
        consumeEscapeBody(&scalars)
      } else if scalar == controlSequenceIntroducer {
        scalars = scalars.dropFirst()
        consumeControlSequence(&scalars)
      } else {
        output.append(scalar)
        scalars = scalars.dropFirst()
      }
    }

    return String(output)
  }

  static func consumeEscapeBody(_ scalars: inout ArraySlice<Unicode.Scalar>) {
    guard let introducer = scalars.first else {
      return
    }
    scalars = scalars.dropFirst()
    switch introducer {
    case "[":
      consumeControlSequence(&scalars)
    case "]":
      consumeOperatingSystemCommand(&scalars)
    default:
      // A two-character escape: the introducer was the whole sequence.
      break
    }
  }

  /// A CSI runs until its final byte in `@`...`~`; everything before it is parameter and
  /// intermediate bytes.
  static func consumeControlSequence(_ scalars: inout ArraySlice<Unicode.Scalar>) {
    while let scalar = scalars.first {
      scalars = scalars.dropFirst()
      if ("\u{40}"..."\u{7E}").contains(scalar) {
        return
      }
    }
  }

  /// An OSC string runs until BEL or ST (`ESC \`).
  static func consumeOperatingSystemCommand(_ scalars: inout ArraySlice<Unicode.Scalar>) {
    while let scalar = scalars.first {
      scalars = scalars.dropFirst()
      if scalar == bell {
        return
      }
      guard scalar == escape else {
        continue
      }
      if scalars.first == "\\" {
        scalars = scalars.dropFirst()
      }
      return
    }
  }
}

// MARK: - Text Normalizing

private extension ChatGPTWireValues {
  /// Drops what survived escape stripping: a stray control carries no meaning here, and one kept as
  /// a literal would still reach a terminal. Whitespace controls are preserved for the collapse
  /// that follows, so a newline becomes a separator rather than joining two words.
  static func strippingControls(_ raw: String) -> String {
    String(
      String.UnicodeScalarView(
        raw.unicodeScalars.filter { scalar in
          isControl(scalar) == false || isWhitespace(scalar)
        }
      )
    )
  }

  /// Folds every whitespace run to a single space and trims the ends, so remote text occupies one
  /// predictable line wherever it is shown.
  static func collapsingWhitespace(_ raw: String) -> String {
    raw.split(whereSeparator: isWhitespace).joined(separator: " ")
  }

  static func isWhitespace(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy(isWhitespace)
  }
}
