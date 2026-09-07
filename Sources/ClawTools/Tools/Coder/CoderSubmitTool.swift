import ClawCore
import Foundation

public struct CoderSubmitTool: Tool {
  private let service: any CoderServing
  private let executionPolicyID: String
  private let redactor: SecretRedactor

  public init(service: any CoderServing, executionPolicyID: String, redactor: SecretRedactor) {
    self.service = service
    self.executionPolicyID = executionPolicyID
    self.redactor = redactor
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: CoderToolNames.submit,
      description:
        "Delegate a coding task to the owner's native Codex installation after approval.",
      parameters: CoderSubmitArguments.schema,
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .dangerous,
      invocationIdentity: executionPolicyID,
      requiresInteractiveRequester: true,
      requiresGroupApproval: true
    )
  }

  public var timeout: Duration { .seconds(30) }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  public func prepareAction(arguments: JSONValue) async -> PreparedActionResolution? {
    do {
      let request = try CoderSubmitArguments.decode(arguments)
      let prepared = try await service.prepare(request)
      guard prepared.executionPolicyID == executionPolicyID,
        let canonical = CanonicalJSON.encode(prepared)
      else {
        return .refused(reason: "The Coder execution policy changed; request fresh approval.")
      }
      return .prepared(
        PreparedToolAction(
          canonicalTarget: prepared.canonicalSource,
          canonicalArgsJSON: canonical,
          presentation: Self.presentation(prepared, redactor: redactor),
          guardTexts: Self.guardTexts(prepared),
          canExfiltrate: true,
          approvalReason: .coderSubmit
        )
      )
    } catch {
      return .refused(reason: CoderToolOutput.failure(error, redactor: redactor).content)
    }
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    CoderToolOutput.missingContext
  }

  public func execute(
    arguments: JSONValue,
    canonicalTarget: String?,
    context: ToolExecutionContext?
  ) async -> ToolPayload {
    guard let context, context.approvalId != nil else {
      return CoderToolOutput.missingContext
    }
    guard let canonical = CanonicalJSON.encode(arguments),
      let prepared = try? JSONDecoder().decode(
        CoderPreparedRequest.self,
        from: Data(canonical.utf8)
      ),
      prepared.canonicalSource == canonicalTarget,
      prepared.executionPolicyID == executionPolicyID
    else {
      return CoderToolOutput.failure(CoderError.staleApproval, redactor: redactor)
    }
    do {
      let job = try await service.submit(prepared, context: context)
      return CoderToolOutput.job(job, redactor: redactor)
    } catch {
      return CoderToolOutput.failure(error, redactor: redactor)
    }
  }
}

// MARK: - Outbound Argument Guard

private extension CoderSubmitTool {
  static func guardTexts(_ prepared: CoderPreparedRequest) -> [String] {
    let request = prepared.request
    let source: String
    switch request.source {
    case .local(let value), .githubRepository(let value), .githubIssue(let value): source = value
    }
    var texts = [source, request.task, request.instructions, request.startRef]
    if request.workspace == .inPlace { texts.append(prepared.checkoutPath) }
    if request.deliverable == .pullRequest {
      texts += [request.baseBranch, prepared.publicationRepository]
    }
    return texts.compactMap { text in
      text
    }
  }
}

// MARK: - Approval Presentation

extension CoderSubmitTool {
  static func presentation(
    _ prepared: CoderPreparedRequest,
    redactor: SecretRedactor
  ) -> ToolApprovalPresentation {
    let request = prepared.request
    let source: String
    if case .githubIssue(let url) = request.source {
      source = "GitHub issue \(url) (repository: \(prepared.canonicalSource))"
    } else {
      source = prepared.canonicalSource
    }
    let workspace =
      request.workspace == .inPlace
      ? "In place — existing branch and working files"
      : "Separate copy — committed history only"
    let start =
      request.workspace == .inPlace
      ? "Current checkout HEAD"
      : request.startRef ?? "Source HEAD / remote default branch"
    let fields = [
      ("Source", source),
      ("Workspace", workspace),
      ("Start ref", start),
      ("Deliverable", request.deliverable == .pullRequest ? "Pull request" : "Local changes"),
      (
        "PR repository",
        request.deliverable == .pullRequest
          ? prepared.publicationRepository ?? prepared.canonicalSource : "Not requested"
      ),
      (
        "PR base",
        request.baseBranch
          ?? (request.deliverable == .pullRequest ? "Repository default branch" : "Not applicable")
      ),
      ("Include existing changes", request.publishExistingChanges ? "Yes" : "No"),
    ]
    let scope = fields.map { label, value in
      CoderCardMarkdown.field(label, redactor.redact(value))
    }.joined(separator: "\n\n")
    let task =
      request.task.map { value in
        CoderCardMarkdown.literal(redactor.redact(value))
      } ?? "Use the selected GitHub issue as the task; no additional task text supplied."
    let instructions =
      request.instructions.map { value in
        CoderCardMarkdown.literal(redactor.redact(value))
      } ?? "None supplied."
    return ToolApprovalPresentation(
      blastRadius: scope,
      contentPreview: "### Task\n\n\(task)\n\n### Instructions\n\n\(instructions)",
      warnings: [
        "Uses your trusted native Codex installation, credentials and configured integrations. Inference leaves this machine; the working directory is not a security sandbox."
      ]
    )
  }
}
