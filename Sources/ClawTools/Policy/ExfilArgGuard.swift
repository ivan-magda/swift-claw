import Foundation

/// FR-T6's blocking arg guard — the §9.1 pinned contract (review H4). Pure: secrets are injected
/// at construction; tier-3 file texts are injected per evaluation (the GATE loads them from disk
/// at evaluation time, rev.1 H1).
public struct ExfilArgGuard: Sendable {
  public struct Verdict: Sendable, Equatable {
    public let blockedRule: String?
    public let redactedArgs: String
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
    let candidates = Self.matchCandidates(argsJSON)

    for candidate in candidates {
      for secret in secretValues where candidate.contains(secret) {
        return blockedVerdict(rule: "secret-value", raw: argsJSON, spans: [secret])
      }
    }

    for candidate in candidates {
      for (rule, pattern) in Self.shapePatterns {
        let matches = Self.regexMatches(pattern, in: candidate).filter { match in
          rule != "high-entropy" || Self.looksHighEntropy(match)
        }
        if matches.isEmpty == false {
          return blockedVerdict(rule: rule, raw: argsJSON, spans: matches)
        }
      }
    }

    return Verdict(blockedRule: nil, redactedArgs: renderRedacted(argsJSON: argsJSON))
  }

  // MARK: - Tier 3 (trifecta condition only)

  public func evaluateConditional(argsJSON: String, privateFileTexts: [String]) -> Verdict {
    let threshold = Self.substringThresholdGraphemes
    let normalizedFiles = privateFileTexts.map { text in
      text.precomposedStringWithCanonicalMapping
    }

    for candidate in Self.matchCandidates(argsJSON) {
      let normalizedCandidate = candidate.precomposedStringWithCanonicalMapping
      let graphemes = Array(normalizedCandidate)

      guard graphemes.count >= threshold else {
        continue
      }

      for start in 0...(graphemes.count - threshold) {
        let window = String(graphemes[start..<(start + threshold)])
        if normalizedFiles.contains(where: { fileText in fileText.contains(window) }) {
          return blockedVerdict(rule: "private-file-substring", raw: argsJSON, spans: [window])
        }
      }
    }

    return Verdict(blockedRule: nil, redactedArgs: renderRedacted(argsJSON: argsJSON))
  }

  // MARK: - Audit rendering

  /// The §9.1 rendering pass on its own — used for ALLOWED calls' audit rows too, so an audit row
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

  /// Normalization order (review H4): NFC first, then ≤2 percent-decode passes; match the raw
  /// string AND every decoded stage (belt-and-braces). Decoding is best-effort (M1): a stray
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
  /// spans so an appended `%ZZ` can't shield an encoded secret (M1). Returns nil when nothing was
  /// decoded (so the caller stops the pass loop) or when the decoded bytes aren't valid UTF-8.
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

  /// The deterministic stand-in for entropy (§9.1): ≥1 digit AND both letter cases.
  static func looksHighEntropy(_ token: String) -> Bool {
    token.contains(where: \.isNumber)
      && token.contains(where: \.isUppercase)
      && token.contains(where: \.isLowercase)
  }

  /// Runs a full redaction sweep over the RAW string so a span only present in a decoded candidate
  /// can't be located in the raw bytes, so the whole args string is redacted instead — the audit
  /// row must never re-contain the matched material.
  private func blockedVerdict(rule: String, raw: String, spans: [String]) -> Verdict {
    // Full sweep first so a SECOND loaded secret or shaped token in the same args can never
    // survive into the audit row (§9.1 — the row must never re-contain matched material).
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
