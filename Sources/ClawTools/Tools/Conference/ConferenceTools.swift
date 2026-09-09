import ClawCore
import Foundation

public struct ConferenceCurrentTool: Tool {
  private let service: any ConferenceServing

  public init(service: any ConferenceServing) {
    self.service = service
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: ConferenceToolNames.current,
      description: "Return the currently active conference coding challenge case.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
      ]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe
    )
  }

  public var timeout: Duration { .seconds(5) }
  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    do {
      let item = try await service.currentCase()
      return .init(
        content: """
          Case \(item.id): \(item.title)

          \(item.prompt)
          """,
        status: .ok,
        ingestedUntrusted: false
      )
    } catch {
      return Self.failure(error)
    }
  }
}

public struct ConferenceSubmitTool: Tool {
  private let service: any ConferenceServing
  private let invocationIdentity: String
  private let redactor: SecretRedactor

  public init(
    service: any ConferenceServing,
    invocationIdentity: String,
    redactor: SecretRedactor
  ) {
    self.service = service
    self.invocationIdentity = invocationIdentity
    self.redactor = redactor
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: ConferenceToolNames.submit,
      description: """
        Submit the participant's own exact proposal for the active conference case. Do not invent \
        or improve the proposal before submitting it. The action requires explicit confirmation and \
        queues an isolated background Coder run.
        """,
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "answer": .object([
            "type": .string("string"),
            "description": .string("The participant's exact proposal, preserved verbatim."),
            "maxLength": .integer(12_000),
          ])
        ]),
        "required": .array([.string("answer")]),
        "additionalProperties": .bool(false),
      ]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .dangerous,
      invocationIdentity: invocationIdentity,
      requiresInteractiveRequester: true,
      requiresGroupApproval: true
    )
  }

  public var timeout: Duration { .seconds(10) }
  public var executesOnlyViaApproval: Bool { true }
  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  public func prepareAction(arguments: JSONValue) async -> PreparedActionResolution? {
    guard let answer = arguments.objectValue?["answer"]?.stringValue else {
      return .refused(reason: "challenge_submit requires an answer string.")
    }
    do {
      let prepared = try await service.prepareSubmission(answer: answer)
      guard let canonical = CanonicalJSON.encode(prepared) else {
        return .refused(reason: "The conference submission could not be prepared safely.")
      }
      let item = prepared.caseSnapshot
      return .prepared(
        PreparedToolAction(
          canonicalTarget: "conference:\(item.id):\(item.repositoryURL)@\(item.baselineRef)",
          canonicalArgsJSON: canonical,
          presentation: ToolApprovalPresentation(
            blastRadius: """
              Case: \(redactor.redact(item.id)) — \(redactor.redact(item.title))
              Repository: \(redactor.redact(item.repositoryURL))
              Baseline: \(redactor.redact(item.baselineRef))
              PR base: \(redactor.redact(item.baseBranch))
              Result: queued Coder run + pull request; never auto-merged
              """,
            contentPreview: redactor.redact(prepared.answer),
            warnings: [
              "The coding agent must preserve your proposal; generated code can still require human review."
            ]
          ),
          guardTexts: [
            item.repositoryURL, item.baselineRef, item.baseBranch, item.prompt, prepared.answer,
          ],
          canExfiltrate: true,
          approvalReason: .conferenceSubmit
        )
      )
    } catch {
      return .refused(reason: Self.failureMessage(error))
    }
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    Self.missingApproval
  }

  public func execute(
    arguments: JSONValue,
    canonicalTarget: String?,
    context: ToolExecutionContext?
  ) async -> ToolPayload {
    guard let context, context.approvalId != nil else { return Self.missingApproval }
    guard let canonical = CanonicalJSON.encode(arguments),
      let prepared = try? JSONDecoder().decode(
        PreparedConferenceSubmission.self,
        from: Data(canonical.utf8)
      )
    else {
      return Self.failure(ConferenceError.staleCase)
    }
    let expectedTarget =
      "conference:\(prepared.caseSnapshot.id):\(prepared.caseSnapshot.repositoryURL)@\(prepared.caseSnapshot.baselineRef)"
    guard canonicalTarget == expectedTarget else {
      return Self.failure(ConferenceError.staleCase)
    }

    do {
      let submission = try await service.submit(prepared, context: context)
      return .init(
        content: "Submission \(submission.id.uuidString.lowercased()) is \(submission.state.rawValue).",
        status: .ok,
        ingestedUntrusted: false
      )
    } catch {
      return Self.failure(error)
    }
  }
}

public struct ConferenceStatusTool: Tool {
  private let service: any ConferenceServing

  public init(service: any ConferenceServing) {
    self.service = service
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: ConferenceToolNames.status,
      description:
        "Return the current participant's conference submission status and pull request when available.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "submission_id": .object([
            "type": .string("string"),
            "description": .string("Optional submission UUID. Omit for the active case."),
          ])
        ]),
        "additionalProperties": .bool(false),
      ]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe,
      requiresInteractiveRequester: true
    )
  }

  public var timeout: Duration { .seconds(5) }
  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    Self.missingContext
  }

  public func execute(
    arguments: JSONValue,
    canonicalTarget: String?,
    context: ToolExecutionContext?
  ) async -> ToolPayload {
    guard let context else { return Self.missingContext }
    let idText = arguments.objectValue?["submission_id"]?.stringValue
    let id: UUID?
    if let idText {
      guard let parsed = UUID(uuidString: idText) else {
        return Self.failure(ConferenceError.notFound)
      }
      id = parsed
    } else {
      id = nil
    }

    do {
      guard let submission = try await service.status(submissionID: id, context: context) else {
        return .init(
          content: "No submission found for this participant and case.",
          status: .ok,
          ingestedUntrusted: false
        )
      }
      var lines = [
        "Submission: \(submission.id.uuidString.lowercased())",
        "Case: \(submission.caseSnapshot.id)",
        "State: \(submission.state.rawValue)",
      ]
      if let url = submission.pullRequestURL { lines.append("Pull request: \(url)") }
      if let reason = submission.failureReason { lines.append("Note: \(reason)") }
      return .init(content: lines.joined(separator: "\n"), status: .ok, ingestedUntrusted: false)
    } catch {
      return Self.failure(error)
    }
  }
}

// MARK: - Safe output

private extension ConferenceCurrentTool {
  static func failure(_ error: any Error) -> ToolPayload {
    ConferenceToolOutput.failure(error)
  }
}

private extension ConferenceSubmitTool {
  static let missingApproval = ToolPayload(
    content: "Conference submission requires its recorded approval context.",
    status: .error,
    ingestedUntrusted: false
  )

  static func failure(_ error: any Error) -> ToolPayload { ConferenceToolOutput.failure(error) }
  static func failureMessage(_ error: any Error) -> String { ConferenceToolOutput.message(error) }
}

private extension ConferenceStatusTool {
  static let missingContext = ToolPayload(
    content: "Conference status requires an interactive participant context.",
    status: .error,
    ingestedUntrusted: false
  )

  static func failure(_ error: any Error) -> ToolPayload { ConferenceToolOutput.failure(error) }
}

private enum ConferenceToolOutput {
  static func failure(_ error: any Error) -> ToolPayload {
    ToolPayload(content: message(error), status: .error, ingestedUntrusted: false)
  }

  static func message(_ error: any Error) -> String {
    switch error {
    case ConferenceError.disabled: return "Conference challenge is disabled."
    case ConferenceError.noActiveCase: return "There is no active conference case."
    case ConferenceError.invalidContext: return "A verified participant identity is required."
    case ConferenceError.forbidden: return "That submission belongs to another participant."
    case ConferenceError.notFound: return "Submission not found."
    case ConferenceError.staleCase: return "The active case changed; request the current case again."
    case ConferenceError.invalidAnswer(let reason): return reason
    case ConferenceError.duplicateSubmission(let id):
      return "You already submitted this case as \(id.uuidString.lowercased())."
    case ConferenceError.coderUnavailable(_): return "The conference Coder is unavailable."
    case is StoreError: return "Conference storage is unavailable."
    default: return "Conference workflow failed."
    }
  }
}
