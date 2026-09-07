import ClawCore
import Foundation

public struct CoderCancelTool: Tool {
  private let service: any CoderServing
  private let redactor: SecretRedactor

  public init(service: any CoderServing, redactor: SecretRedactor) {
    self.service = service
    self.redactor = redactor
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: CoderToolNames.cancel,
      description: "Request cancellation of an owned background Coder job.",
      parameters: CoderToolOutput.jobSchema,
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe,
      requiresInteractiveRequester: true
    )
  }

  public var timeout: Duration { .seconds(30) }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    CoderToolOutput.missingContext
  }

  public func execute(
    arguments: JSONValue,
    canonicalTarget: String?,
    context: ToolExecutionContext?
  ) async -> ToolPayload {
    guard let context else {
      return CoderToolOutput.missingContext
    }
    guard let id = CoderToolOutput.jobID(arguments) else {
      return CoderToolOutput.failure(
        CoderError.invalidRequest("Provide only job_id as a UUID string."),
        redactor: redactor
      )
    }
    do {
      return CoderToolOutput.job(
        try await service.cancel(id: id, context: context),
        redactor: redactor
      )
    } catch {
      return CoderToolOutput.failure(error, redactor: redactor)
    }
  }
}
