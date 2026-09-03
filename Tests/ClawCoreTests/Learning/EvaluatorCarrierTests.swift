import ClawCore
import Foundation
import Testing

/// Every token a run's private learning state would spell if the carrier forwarded its evidence
/// payload instead of projecting named fields out of it. The rubric travels inside the carrier, so
/// this list also bounds how the rubric may be worded.
private let forbiddenCarrierTokens = [
  "lesson", "trial", "candidate", "digest", "promotion", "stable", "score", "expected", "gold",
  "oracle",
]

/// Replies the frozen evaluator schema refuses: an extra key, a version that is not the frozen one,
/// an outcome outside the closed vocabulary, a code carrying no identity, and both bounds.
private let repliesOutsideTheFrozenSchema: [String] = [
  #"{"schema_version":1,"outcome":"no_issue","issue_codes":[],"confidence":0.9}"#,
  #"{"schema_version":2,"outcome":"no_issue","issue_codes":[]}"#,
  #"{"schema_version":1,"outcome":"maybe","issue_codes":[]}"#,
  #"{"schema_version":1,"outcome":"no_issue"}"#,
  #"{"schema_version":1,"outcome":"reusable_issue","issue_codes":[""]}"#,
  reply(issueCodes: (0...EvaluatorOutput.maxIssueCodes).map { "code_\($0)" }),
  reply(issueCodes: [String(repeating: "x", count: EvaluatorOutput.maxIssueCodeCharacters + 1)]),
]

private func reply(issueCodes: [String]) -> String {
  let codes = issueCodes.map { code in
    "\"\(code)\""
  }
  return
    "{\"schema_version\":1,\"outcome\":\"reusable_issue\",\"issue_codes\":[\(codes.joined(separator: ","))]}"
}

/// The evaluator is blind by construction, not by convention: `EvaluatorCarrier` is the whole
/// model-visible surface of a run, and `EvaluatorOutput` is the whole reply the algorithm accepts
/// back. Both are closed types, so widening either is a visible trust decision.
@Suite struct EvaluatorCarrierTests {
  @Test func serializedCarrierHoldsNoLessonTrialOrCandidateField() throws {
    // given — a payload whose lesson-set and job-definition digests spell the forbidden tokens
    let carrier = EvaluatorCarrier(
      runId: 41,
      jobPrompt: "Check the page for material changes.",
      rubric: EvaluatorRubric.v1.text,
      evidence: evidencePayload()
    )

    // when
    let encoded = String(decoding: try JSONEncoder().encode(carrier), as: UTF8.self)

    // then — nothing about what the run was told, and only the named fields copied out
    for token in forbiddenCarrierTokens {
      #expect(encoded.lowercased().contains(token) == false, "carrier leaked \(token)")
    }
    #expect(carrier.finalOutput == "The price changed from 10 to 12.")
    #expect(carrier.evidence.toolCallCount == 2)
    #expect(carrier.evidence.terminalRoute == "openai-compatible/gpt-x")
  }

  @Test(arguments: repliesOutsideTheFrozenSchema)
  func aReplyOutsideTheFrozenSchemaIsRejected(_ json: String) throws {
    // given, when
    let decoded = try? JSONDecoder().decode(EvaluatorOutput.self, from: Data(json.utf8))

    // then — a decode failure is terminal for the operation, so it must not be recoverable here
    #expect(decoded == nil)
  }

  @Test func issueCodesAreStoredSortedSoTwoRunsCompareByExactEquality() throws {
    // given — the same two codes a second run could report in the other order
    let json = """
      {"schema_version":1,"outcome":"reusable_issue",\
      "issue_codes":["missed_price_change","empty_answer"]}
      """

    // when
    let output = try JSONDecoder().decode(EvaluatorOutput.self, from: Data(json.utf8))

    // then
    #expect(output.outcome == .reusableIssue)
    #expect(output.issueCodes == ["empty_answer", "missed_price_change"])
  }
}

// MARK: - Fixture

private func evidencePayload() -> EvidencePayload {
  EvidencePayload(
    schemaVersion: EvidenceLimits.schemaVersion,
    jobDefinitionDigest: "digest-of-the-job-definition",
    effectiveLessonSetDigest: "lesson-set-the-run-was-told",
    sourceMessageId: 7,
    sourceDigest: "digest-of-this-receipt",
    finalOutput: "The price changed from 10 to 12.",
    toolFacts: [
      EvidenceToolFact(ordinal: 0, name: "web_fetch", observed: true),
      EvidenceToolFact(ordinal: 1, name: "web_fetch", observed: true),
    ],
    proposedCalls: 2,
    observedCalls: 2,
    contextSchemaVersion: "ctx-1",
    toolCatalogDigest: "tools-v1",
    policyVersion: "pv16",
    skillSetDigest: "skills-v1",
    configuredRoute: "openai-compatible/gpt-x",
    terminalRoute: "openai-compatible/gpt-x",
    usageRowIds: [11]
  )
}
