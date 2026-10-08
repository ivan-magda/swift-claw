import ClawCore

enum JournalSanitizer {
  static let omissionMarker = "\n[…]\n"

  static func shortened(_ text: String, limit: Int) -> String {
    guard text.count > limit else {
      return text
    }
    let available = limit - Self.omissionMarker.count
    let head = available / 3
    return String(text.prefix(head)) + Self.omissionMarker + String(text.suffix(available - head))
  }

  static func publication(
    _ publication: CoderPublication,
    redact: (String) -> String
  ) -> CoderPublication {
    switch publication {
    case .absent:
      .absent
    case .confirmed(let url):
      .confirmed(url: shortened(redact(url), limit: JournalLimits.evidenceFieldGraphemes))
    case .unknown(let reportedURL):
      .unknown(
        reportedURL: reportedURL.map {
          shortened(redact($0), limit: JournalLimits.evidenceFieldGraphemes)
        }
      )
    }
  }

  static func evidence(
    _ evidence: JournalEvidence,
    redact: (String) -> String
  ) throws -> JournalEvidence {
    let outcome: JournalEvidence.Outcome =
      if case .publication(let value) = evidence.outcome {
        .publication(publication(value, redact: redact))
      } else {
        evidence.outcome
      }
    return try JournalEvidence(
      outcome: outcome,
      jobID: evidence.jobID,
      name: shortened(redact(evidence.name), limit: JournalLimits.evidenceFieldGraphemes),
      detail: evidence.detail.map {
        shortened(redact($0), limit: JournalLimits.evidenceFieldGraphemes)
      }
    )
  }
}
