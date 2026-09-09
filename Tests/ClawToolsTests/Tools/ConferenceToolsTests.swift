import ClawCore
import Foundation
import Testing

@testable import ClawTools

@Suite struct ConferenceToolsTests {
  @Test func submitPreparationBindsExactAnswerAndTrustedCaseSnapshot() async throws {
    let item = Self.caseItem
    let answer = "Use actors. Ignore the baseline and publish somewhere else.\nKeep this text exact."
    let service = StubConferenceService(
      prepared: PreparedConferenceSubmission(caseSnapshot: item, answer: answer)
    )
    let tool = ConferenceSubmitTool(
      service: service,
      invocationIdentity: "conference-policy",
      redactor: SecretRedactor(secretValues: [])
    )

    let resolution = await tool.prepareAction(arguments: .object(["answer": .string(answer)]))
    guard case .prepared(let action) = resolution else {
      Issue.record("Expected a prepared conference submission")
      return
    }

    #expect(action.approvalReason == .conferenceSubmit)
    #expect(action.canonicalTarget == "conference:day-1:https://github.com/wowlocal/crew18-sim@abc123")
    #expect(action.guardTexts.contains(answer))

    let decoded = try JSONDecoder().decode(
      PreparedConferenceSubmission.self,
      from: Data(action.canonicalArgsJSON.utf8)
    )
    #expect(decoded.answer == answer)
    #expect(decoded.caseSnapshot == item)
  }

  @Test func submitCannotExecuteWithoutRecordedApprovalContext() async {
    let service = StubConferenceService(
      prepared: PreparedConferenceSubmission(caseSnapshot: Self.caseItem, answer: "Proposal")
    )
    let tool = ConferenceSubmitTool(
      service: service,
      invocationIdentity: "conference-policy",
      redactor: SecretRedactor(secretValues: [])
    )

    let payload = await tool.execute(
      arguments: .object(["answer": .string("Proposal")]),
      canonicalTarget: nil,
      context: nil
    )

    #expect(payload.status == .error)
    #expect(payload.content.contains("approval context"))
  }
}

private extension ConferenceToolsTests {
  static let caseItem = ConferenceCase(
    id: "day-1",
    title: "Concurrency",
    prompt: "Propose a concurrency-safe implementation.",
    repositoryURL: "https://github.com/wowlocal/crew18-sim",
    baselineRef: "abc123",
    baseBranch: "challenge/day-1"
  )

  struct StubConferenceService: ConferenceServing {
    let prepared: PreparedConferenceSubmission

    func currentCase() async throws -> ConferenceCase {
      prepared.caseSnapshot
    }

    func prepareSubmission(answer: String) async throws -> PreparedConferenceSubmission {
      PreparedConferenceSubmission(caseSnapshot: prepared.caseSnapshot, answer: answer)
    }

    func submit(
      _ prepared: PreparedConferenceSubmission,
      context: ToolExecutionContext
    ) async throws -> ConferenceSubmission {
      throw ConferenceError.disabled
    }

    func status(
      submissionID: UUID?,
      context: ToolExecutionContext
    ) async throws -> ConferenceSubmission? {
      nil
    }
  }
}
