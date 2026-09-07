import ClawCore
import Foundation

enum CoderToolOutput {
  static let missingContext = ToolPayload(
    content: "Coder requires trusted owner context and submission requires durable approval.",
    status: .error,
    ingestedUntrusted: false
  )

  static let jobSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object(["job_id": .object(["type": .string("string")])]),
    "required": .array([.string("job_id")]), "additionalProperties": .bool(false),
  ])

  static func jobID(_ arguments: JSONValue) -> UUID? {
    guard let object = arguments.objectValue, Set(object.keys) == ["job_id"],
      let raw = object["job_id"]?.stringValue
    else {
      return nil
    }
    return UUID(uuidString: raw)
  }

  static func job(_ job: CoderJob, redactor: SecretRedactor) -> ToolPayload {
    let result =
      job.result.flatMap(CanonicalJSON.encode).flatMap(JSONValue.parse).map { value in
        redact(value, using: redactor)
      }.flatMap(CanonicalJSON.encode) ?? "Result pending."
    let header = redactor.redact("Coder job \(job.id.uuidString)\nState: \(job.state.rawValue)")
    let text = "\(header)\n\(result)"
    return ToolPayload(
      content: ToolOutputCap.cap(text),
      status: .ok,
      ingestedUntrusted: job.result != nil
    )
  }

  static func failure(_ error: any Error, redactor: SecretRedactor) -> ToolPayload {
    let content: String
    switch error {
    case CoderError.invalidRequest(let reason), CoderError.unavailable(let reason):
      content = reason
    case CoderError.forbidden:
      content = "That Coder job is not available to this requester."
    case CoderError.busy:
      content = "Coder is at capacity; try again when a running job finishes."
    case CoderError.workspaceBusy:
      content = "Coder already has an active task in that checkout."
    case CoderError.staleApproval:
      content = "The Coder request or execution policy changed; request fresh approval."
    case CoderError.recoveryRequired:
      content = "Coder requires operator recovery before accepting this task."
    default:
      content = "Coder could not complete this operation."
    }
    return ToolPayload(
      content: ToolOutputCap.cap(redactor.redact(content)),
      status: .error,
      ingestedUntrusted: false
    )
  }
}

// MARK: - Structured Result Redaction

private extension CoderToolOutput {
  static func redact(_ value: JSONValue, using redactor: SecretRedactor) -> JSONValue {
    switch value {
    case .string(let text):
      return .string(redactor.redact(text))
    case .array(let values):
      return .array(
        values.map { value in
          redact(value, using: redactor)
        }
      )
    case .object(let fields):
      return .object(
        fields.reduce(into: [:]) { result, field in
          result[redactor.redact(field.key)] = redact(field.value, using: redactor)
        }
      )
    default:
      return value
    }
  }
}
