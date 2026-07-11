import Foundation

/// The blocking arg guard. Pure: secrets are injected at construction; tier-3 file texts are
/// injected per evaluation (the GATE loads them from disk at evaluation time).
public struct ExfilArgGuard: Sendable {
  public struct Verdict: Sendable, Equatable {
    public let blockedRule: String?
    public let redactedArgs: String
  }

  public struct PrivateTextIndex: Sendable {
    /// A window's provenance: which normalized source it came from and where it starts. The
    /// window graphemes themselves live once in `sources`, not copied per overlapping position.
    private struct Window: Sendable {
      let source: Int
      let start: Int
    }

    /// Each source text normalized to NFC and stored ONCE, only for sources long enough to hold a
    /// full window. Confirmation slices back into these rather than into duplicated window arrays.
    private let sources: [[Character]]
    private let windowsByFingerprint: [UInt64: [Window]]

    public init(texts: [String]) {
      let width = ExfilArgGuard.substringThresholdGraphemes
      var storedSources: [[Character]] = []
      var indexed: [UInt64: [Window]] = [:]

      for text in texts {
        let characters = Array(text.precomposedStringWithCanonicalMapping)
        guard characters.count >= width else {
          continue
        }

        let sourceIndex = storedSources.count
        storedSources.append(characters)

        for start in 0...(characters.count - width) {
          let fingerprint = ExfilArgGuard.windowFingerprint(characters[start..<(start + width)])
          indexed[fingerprint, default: []].append(Window(source: sourceIndex, start: start))
        }
      }

      sources = storedSources
      windowsByFingerprint = indexed
    }

    fileprivate func firstMatch(in text: String) -> String? {
      let width = ExfilArgGuard.substringThresholdGraphemes
      let characters = Array(text.precomposedStringWithCanonicalMapping)
      guard characters.count >= width else {
        return nil
      }

      for start in 0...(characters.count - width) {
        let candidate = characters[start..<(start + width)]
        let fingerprint = ExfilArgGuard.windowFingerprint(candidate)
        guard let windows = windowsByFingerprint[fingerprint] else {
          continue
        }
        // The fingerprint only narrows the set; confirm grapheme-for-grapheme so a hash
        // collision can never false-block.
        let matched = windows.contains { window in
          let source = sources[window.source]
          return candidate.elementsEqual(source[window.start..<(window.start + width)])
        }
        if matched {
          return String(candidate)
        }
      }

      return nil
    }
  }

  /// Tier 2 — the pinned v1 secret-shape table. Order matters: first match names the rule.
  static let shapePatterns: [(rule: String, pattern: String)] = [
    ("openai-key", "sk-[A-Za-z0-9_-]{16,}"),
    ("github-token", "gh[pousr]_[A-Za-z0-9]{20,}"),
    ("github-token", "github_pat_[A-Za-z0-9_]{20,}"),
    ("slack-token", "xox[bpoas]-[A-Za-z0-9-]{10,}"),
    ("aws-access-key", "AKIA[A-Z0-9]{16}"),
    ("google-api-key", "AIza[A-Za-z0-9_-]{30,}"),
    ("telegram-bot-token", "[0-9]{8,10}:[A-Za-z0-9_-]{35}"),
    ("high-entropy", "[A-Za-z0-9+/=_-]{40,}"),
  ]

  static let substringThresholdGraphemes = 16
  static let maxPercentDecodePasses = 2

  private let secretValues: [String]

  public init(secretValues: [String]) {
    self.secretValues = secretValues.filter { value in value.isEmpty == false }
  }

  // MARK: - Tiers 1 + 2 (always)

  public func evaluateUnconditional(argsJSON: String) -> Verdict {
    evaluate(text: argsJSON)
  }

  public func evaluate(text: String) -> Verdict {
    let candidates = Self.matchCandidates(text)

    for candidate in candidates {
      for secret in secretValues where candidate.contains(secret) {
        return blockedVerdict(rule: "secret-value", raw: text, spans: [secret])
      }
    }

    for candidate in candidates {
      for (rule, pattern) in Self.shapePatterns {
        let matches = Self.regexMatches(pattern, in: candidate).filter { match in
          rule != "high-entropy" || Self.looksHighEntropy(match)
        }
        if matches.isEmpty == false {
          return blockedVerdict(rule: rule, raw: text, spans: matches)
        }
      }
    }

    return Verdict(blockedRule: nil, redactedArgs: renderRedacted(argsJSON: text))
  }

  // MARK: - Tier 3 (trifecta condition only)

  public func evaluateConditional(argsJSON: String, privateFileTexts: [String]) -> Verdict {
    evaluateConditional(
      text: argsJSON,
      index: PrivateTextIndex(texts: privateFileTexts)
    )
  }

  public func evaluateConditional(text: String, index: PrivateTextIndex) -> Verdict {
    for candidate in Self.matchCandidates(text) {
      if let window = index.firstMatch(in: candidate) {
        return blockedVerdict(
          rule: "private-file-substring",
          raw: text,
          spans: [window]
        )
      }
    }

    return Verdict(blockedRule: nil, redactedArgs: renderRedacted(argsJSON: text))
  }

  // MARK: - Audit rendering

  /// The rendering pass on its own — used for ALLOWED calls' audit rows too, so an audit row
  /// can never re-contain a secret whatever the verdict.
  public func renderRedacted(argsJSON: String) -> String {
    var rendered = argsJSON

    for secret in secretValues {
      rendered = rendered.replacingOccurrences(of: secret, with: "[REDACTED:secret-value]")
    }

    for (rule, pattern) in Self.shapePatterns {
      for match in Self.regexMatches(pattern, in: rendered)
      where rule != "high-entropy" || Self.looksHighEntropy(match) {
        rendered = rendered.replacingOccurrences(of: match, with: "[REDACTED:\(rule)]")
      }
    }

    return rendered
  }

  // MARK: - Load-bearing helpers

  /// Normalization order: NFC first, then ≤2 percent-decode passes; match the raw
  /// string AND every decoded stage (belt-and-braces). Decoding is best-effort: a stray
  /// malformed escape like `%ZZ` must NOT abandon the whole pass and let a well-formed encoded
  /// secret elsewhere in the string slip through unchecked.
  static func matchCandidates(_ argsJSON: String) -> [String] {
    var candidates = [argsJSON]
    var current = argsJSON.precomposedStringWithCanonicalMapping

    if current != argsJSON {
      candidates.append(current)
    }

    for _ in 0..<maxPercentDecodePasses {
      guard let decoded = Self.bestEffortPercentDecode(current), decoded != current else {
        break
      }

      candidates.append(decoded)
      current = decoded
    }

    return candidates
  }

  /// A best-effort percent decoder: decode every valid `%XX` escape and preserve everything else
  /// (a lone `%`, `%` not followed by two hex digits) verbatim. Unlike `removingPercentEncoding`,
  /// which returns nil for the ENTIRE string on any malformed escape, this recovers the decodable
  /// spans so an appended `%ZZ` can't shield an encoded secret. Returns nil only when nothing
  /// was decoded (so the caller stops the pass loop).
  static func bestEffortPercentDecode(_ text: String) -> String? {
    let scalars = Array(text.unicodeScalars)
    var bytes: [UInt8] = []
    var index = 0
    var decodedAny = false

    while index < scalars.count {
      let scalar = scalars[index]

      guard scalar == "%", index + 2 < scalars.count,
        let high = Self.hexNibble(scalars[index + 1]),
        let low = Self.hexNibble(scalars[index + 2])
      else {
        bytes.append(contentsOf: Array(String(scalar).utf8))
        index += 1
        continue
      }

      bytes.append((high << 4) | low)
      index += 3
      decodedAny = true
    }

    guard decodedAny else {
      return nil
    }

    // Deliberately lossy: the failable form returns nil on any invalid UTF-8 byte, letting a
    // single `%FF` shield an otherwise-decodable encoded secret from redaction (fail-open).
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: bytes, as: UTF8.self)
  }

  /// The numeric value 0...15 of a single hex digit, or nil for any non-hex scalar.
  private static func hexNibble(_ scalar: Unicode.Scalar) -> UInt8? {
    switch scalar {
    case "0"..."9":
      return UInt8(scalar.value - Unicode.Scalar("0").value)
    case "a"..."f":
      return UInt8(scalar.value - Unicode.Scalar("a").value + 10)
    case "A"..."F":
      return UInt8(scalar.value - Unicode.Scalar("A").value + 10)
    default:
      return nil
    }
  }

  /// All non-overlapping matches of `pattern` in `text` via Foundation's regex search — no stored
  /// regex objects, so no Sendable concerns.
  static func regexMatches(_ pattern: String, in text: String) -> [String] {
    var matches: [String] = []
    var searchRange = text.startIndex..<text.endIndex

    while let found = text.range(of: pattern, options: .regularExpression, range: searchRange) {
      matches.append(String(text[found]))

      guard found.upperBound < text.endIndex else {
        break
      }

      searchRange = found.upperBound..<text.endIndex
    }

    return matches
  }

  /// The deterministic, pinned stand-in for an entropy measure: ≥1 digit AND both letter cases.
  static func looksHighEntropy(_ token: String) -> Bool {
    token.contains(where: \.isNumber)
      && token.contains(where: \.isUppercase)
      && token.contains(where: \.isLowercase)
  }

  /// A collision-tolerant FNV-1a hash over a grapheme window's UTF-8 bytes, with a byte that
  /// cannot occur in valid UTF-8 mixed in between graphemes so that different grapheme boundaries
  /// can never fold into the same byte stream. It only narrows the candidate set — callers must
  /// still confirm exact `Character` equality before blocking, so a collision cannot false-block.
  static func windowFingerprint<Characters: Collection>(_ characters: Characters) -> UInt64
  where Characters.Element == Character {
    var fingerprint: UInt64 = 0xcbf2_9ce4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01b3

    for character in characters {
      for byte in String(character).utf8 {
        fingerprint ^= UInt64(byte)
        fingerprint = fingerprint &* prime
      }
      fingerprint ^= 0xff
      fingerprint = fingerprint &* prime
    }

    return fingerprint
  }

  /// Runs a full redaction sweep over the RAW string so a span only present in a decoded candidate
  /// can't be located in the raw bytes, so the whole args string is redacted instead — the audit
  /// row must never re-contain the matched material.
  private func blockedVerdict(rule: String, raw: String, spans: [String]) -> Verdict {
    // Full sweep first so a SECOND loaded secret or shaped token in the same args can never
    // survive into the audit row — the row must never re-contain matched material.
    var rendered = renderRedacted(argsJSON: raw)
    for span in spans where rendered.contains(span) {
      // Tier-3 private-file windows aren't covered by renderRedacted; redact them explicitly.
      rendered = rendered.replacingOccurrences(of: span, with: "[REDACTED:\(rule)]")
    }
    // A span present only in a decoded candidate isn't in `raw`, so neither the sweep nor the
    // loop above could remove its still-one-decode-away encoded form — nuke the whole string.
    if spans.contains(where: { span in raw.contains(span) == false }) {
      return Verdict(blockedRule: rule, redactedArgs: "[REDACTED:\(rule)]")
    }
    return Verdict(blockedRule: rule, redactedArgs: rendered)
  }
}
