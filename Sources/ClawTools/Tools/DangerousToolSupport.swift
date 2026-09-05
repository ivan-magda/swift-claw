import ClawCore
import ClawProcess
import Foundation

/// The argument plumbing every dangerous-tier tool shares. Their approvals bind a canonical
/// action, so decode, canonical encoding, and the refusal shape must agree byte for byte no
/// matter which tool asked — a second copy would drift an approval away from what runs.
enum DangerousToolSupport {
  static func decode<Value: Decodable>(_ type: Value.Type, from arguments: JSONValue) -> Value? {
    guard let data = try? JSONEncoder().encode(arguments) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }

  static func canonicalJSON<Value: Encodable>(_ value: Value) -> String? {
    CanonicalJSON.encode(value)
  }

  /// One finished command, in the shape both dangerous-tier tools report it. `statusLine` says
  /// how the command ended, `notes` qualify that ending, and the two streams are the data the
  /// model reads.
  struct CommandOutcome {
    let statusLine: String
    let stdout: String
    let stderr: String
    var notes: [String] = []
    var truncatedRawStreams: Bool = false
    var status: ToolObservationStatus = .ok
  }

  static let rawOutputTruncationNotice =
    "[raw output truncated after the first \(LocalCommandLimits.maxRawStreamMiB) MiB of one or more streams]"

  static func exitStatusLine(_ code: some BinaryInteger) -> String {
    "exit \(code)"
  }

  /// Renders an outcome once: redaction runs over the assembled text, and the output cap runs
  /// last, so a secret straddling the cap boundary is replaced before anything is cut.
  static func outcomePayload(
    _ outcome: CommandOutcome,
    redactor: SecretRedactor,
    readPrivateData: Bool = false
  ) -> ToolPayload {
    var lines = [
      outcome.statusLine,
      "--- stdout ---",
      outcome.stdout,
      "--- stderr ---",
      outcome.stderr,
    ]
    lines.append(contentsOf: outcome.notes)
    if outcome.truncatedRawStreams {
      lines.append(rawOutputTruncationNotice)
    }

    return ToolPayload(
      content: ToolOutputCap.cap(redactor.redact(lines.joined(separator: "\n"))),
      status: outcome.status,
      ingestedUntrusted: true,
      readPrivateData: readPrivateData
    )
  }

  static func errorPayload(_ reason: String, redactor: SecretRedactor) -> ToolPayload {
    ToolPayload(
      content: redactor.redact(reason),
      status: .error,
      ingestedUntrusted: false,
      readPrivateData: false
    )
  }
}
