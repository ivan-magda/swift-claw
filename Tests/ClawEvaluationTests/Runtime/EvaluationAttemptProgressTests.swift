import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationAttemptProgressTests {
  @Test func accountedTokensSaturateInsteadOfTrappingOnProviderExtremes() {
    // given
    let usage = ProviderUsage(
      providerCallID: ProviderCallID(rawValue: "extreme"),
      runId: 1,
      sessionId: 1,
      model: PageEvaluationContract.wireModel,
      promptTokens: .max,
      completionTokens: .max,
      costUSD: 0,
      costSource: .providerReturned,
      isEstimated: false,
      ts: Date(timeIntervalSince1970: 0)
    )

    // when
    let accounted = EvaluationResultAccounting.accountedTokens(
      responsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt,
      usage: [usage]
    )
    let estimatedAccounted = EvaluationResultAccounting.accountedTokens(
      responsesSends: 1,
      usage: [
        ProviderUsage(
          providerCallID: ProviderCallID(rawValue: "estimated"),
          runId: 1,
          sessionId: 1,
          model: PageEvaluationContract.wireModel,
          promptTokens: 1,
          completionTokens: 0,
          costUSD: 0,
          costSource: .heuristic,
          isEstimated: true,
          ts: Date(timeIntervalSince1970: 0)
        )
      ]
    )
    let recorded = EvaluationUsageRecord(usage).totalTokens

    // then
    #expect(accounted == .max)
    #expect(estimatedAccounted == PageEvaluationContract.missingUsageTokenProxy)
    #expect(recorded == .max)
  }

  @Test func attemptProgressRejectsEveryIndependentIdentityAndAccountingMutation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let configuration = configured.configuration
    let second = try makeEvaluationReplacement(
      of: configuration,
      configurationDirectory: root.appendingPathComponent("artifacts", isDirectory: true)
    ).configuration
    let configurations = [configuration, second]
    let invocationID = UUID()
    let invocationConfigurationSHA256 = String(repeating: "a", count: 64)
    let usage = EvaluationUsageRecord(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "progress-validation"),
        runId: 2,
        sessionId: 3,
        model: PageEvaluationContract.wireModel,
        promptTokens: 37,
        completionTokens: 0,
        costUSD: 0,
        costSource: .providerReturned,
        isEstimated: false,
        ts: Date(timeIntervalSince1970: 0)
      )
    )
    let valid = EvaluationAttemptProgressRecord(
      schemaVersion: PageEvaluationContract.schemaVersion,
      invocationID: invocationID,
      invocationConfigurationSHA256: invocationConfigurationSHA256,
      manifestSHA256: configuration.approval.manifestSHA256,
      attempts: [
        EvaluationAttemptProgressEntry(
          attemptID: configuration.attemptID,
          configurationSHA256: try EvaluationAttemptProgressRecord.configurationSHA256(
            configuration
          ),
          responsesRequests: [makeEvaluationResponsesSend(sequence: 1)],
          provenNotStartedResponsesSends: 0,
          credentialHTTPCalls: 0,
          fileReads: 0,
          accountedTokens: 37,
          usage: [usage]
        ),
        EvaluationAttemptProgressEntry(
          attemptID: second.attemptID,
          configurationSHA256: try EvaluationAttemptProgressRecord.configurationSHA256(second),
          responsesRequests: [],
          provenNotStartedResponsesSends: 0,
          credentialHTTPCalls: 0,
          fileReads: 0,
          accountedTokens: 0,
          usage: []
        ),
      ]
    )
    typealias Mutation = (inout [String: Any]) throws -> Void
    func mutateEntry(
      _ object: inout [String: Any],
      _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
      var attempts = try #require(object["attempts"] as? [[String: Any]])
      try mutation(&attempts[0])
      object["attempts"] = attempts
    }
    let mutations: [(String, Mutation)] = [
      ("schema", { $0["schema_version"] = PageEvaluationContract.schemaVersion + 1 }),
      ("invocation", { $0["invocation_id"] = UUID().uuidString.lowercased() }),
      (
        "invocation config",
        {
          $0["invocation_configuration_sha256"] = String(repeating: "b", count: 64)
        }
      ),
      ("manifest", { $0["manifest_sha256"] = String(repeating: "c", count: 64) }),
      (
        "attempt",
        { object in
          try mutateEntry(&object) { $0["attempt_id"] = "other-attempt" }
        }
      ),
      (
        "attempt ID order",
        { object in
          var attempts = try #require(object["attempts"] as? [[String: Any]])
          let first = try #require(attempts[0]["attempt_id"] as? String)
          let second = try #require(attempts[1]["attempt_id"] as? String)
          attempts[0]["attempt_id"] = second
          attempts[1]["attempt_id"] = first
          object["attempts"] = attempts
        }
      ),
      (
        "attempt config",
        { object in
          try mutateEntry(&object) {
            $0["configuration_sha256"] = String(repeating: "d", count: 64)
          }
        }
      ),
      (
        "configuration hash order",
        { object in
          var attempts = try #require(object["attempts"] as? [[String: Any]])
          let first = try #require(attempts[0]["configuration_sha256"] as? String)
          let second = try #require(attempts[1]["configuration_sha256"] as? String)
          attempts[0]["configuration_sha256"] = second
          attempts[1]["configuration_sha256"] = first
          object["attempts"] = attempts
        }
      ),
      (
        "send cap",
        { object in
          try mutateEntry(&object) { entry in
            let request = try #require(
              (entry["responses_requests"] as? [[String: Any]])?.first
            )
            entry["responses_requests"] = [request, request, request]
          }
        }
      ),
      (
        "file-read cap",
        { object in
          try mutateEntry(&object) {
            $0["file_reads"] = PageEvaluationContract.runBudget.maxToolCalls + 1
          }
        }
      ),
      (
        "negative file-read",
        { object in
          try mutateEntry(&object) { $0["file_reads"] = -1 }
        }
      ),
      (
        "credential calls",
        { object in
          try mutateEntry(&object) { $0["credential_http_calls"] = -1 }
        }
      ),
      (
        "negative no-start",
        { object in
          try mutateEntry(&object) { $0["proven_not_started_responses_sends"] = -1 }
        }
      ),
      (
        "no-start plus usage",
        { object in
          try mutateEntry(&object) {
            $0["proven_not_started_responses_sends"] = 1
            $0["accounted_tokens"] = 0
          }
        }
      ),
      (
        "negative usage",
        { object in
          try mutateEntry(&object) { entry in
            var rows = try #require(entry["usage"] as? [[String: Any]])
            rows[0]["prompt_tokens"] = -1
            rows[0]["total_tokens"] = -1
            entry["usage"] = rows
            entry["accounted_tokens"] = 0
          }
        }
      ),
      (
        "negative completion usage",
        { object in
          try mutateEntry(&object) { entry in
            var rows = try #require(entry["usage"] as? [[String: Any]])
            rows[0]["prompt_tokens"] = 0
            rows[0]["completion_tokens"] = -1
            rows[0]["total_tokens"] = -1
            entry["usage"] = rows
            entry["accounted_tokens"] = 0
          }
        }
      ),
      (
        "usage sum",
        { object in
          try mutateEntry(&object) { entry in
            var rows = try #require(entry["usage"] as? [[String: Any]])
            rows[0]["total_tokens"] = 36
            entry["usage"] = rows
            entry["accounted_tokens"] = 36
          }
        }
      ),
      (
        "duplicate provider call",
        { object in
          try mutateEntry(&object) { entry in
            let request = try #require(
              (entry["responses_requests"] as? [[String: Any]])?.first
            )
            let row = try #require((entry["usage"] as? [[String: Any]])?.first)
            entry["responses_requests"] = [request, request]
            entry["usage"] = [row, row]
            entry["accounted_tokens"] = 74
          }
        }
      ),
      (
        "accounted total",
        { object in
          try mutateEntry(&object) { $0["accounted_tokens"] = 36 }
        }
      ),
    ]
    let base = try #require(
      JSONSerialization.jsonObject(with: EvaluationCanonicalJSON.data(encoding: valid))
        as? [String: Any]
    )

    // when
    try valid.validate(
      invocationID: invocationID,
      invocationConfigurationSHA256: invocationConfigurationSHA256,
      configurations: configurations
    )

    // then — every mutation kills a distinct fail-closed ledger guard.
    for (_, mutation) in mutations {
      var object = base
      try mutation(&object)
      let record = try JSONDecoder().decode(
        EvaluationAttemptProgressRecord.self,
        from: EvaluationCanonicalJSON.data(fromJSONObject: object)
      )
      #expect(throws: EvaluationPagePipelineError.invalidBatch("attempt_progress_identity")) {
        try record.validate(
          invocationID: invocationID,
          invocationConfigurationSHA256: invocationConfigurationSHA256,
          configurations: configurations
        )
      }
    }
  }

  @Test func structuralHashNormalizesOnlyProtocolDeclaredEphemeralValues() throws {
    // given
    let firstFence =
      #"<claw-untrusted nonce="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" label="file_read">x</claw-untrusted nonce="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">"#
    let secondFence =
      #"<claw-untrusted nonce="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" label="file_read">x</claw-untrusted nonce="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">"#
    let firstBody = try JSONSerialization.data(
      withJSONObject: ["model": PageEvaluationContract.wireModel, "input": firstFence]
    )
    let secondBody = try JSONSerialization.data(
      withJSONObject: ["model": PageEvaluationContract.wireModel, "input": secondFence]
    )
    let ordinaryA = try JSONSerialization.data(
      withJSONObject: [
        "model": PageEvaluationContract.wireModel,
        "input": #"ordinary nonce="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" text"#,
      ]
    )
    let ordinaryB = try JSONSerialization.data(
      withJSONObject: [
        "model": PageEvaluationContract.wireModel,
        "input": #"ordinary nonce="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" text"#,
      ]
    )
    func secondRequest(
      callID: String,
      reasoning: String,
      path: String,
      fence: String,
      assistantText: String? = nil
    ) throws
      -> Data
    {
      let assistantReplay: [[String: Any]] =
        assistantText.map { text in
          [
            [
              "content": [["text": text, "type": "output_text"]],
              "role": "assistant",
              "status": "completed",
              "type": "message",
            ]
          ]
        } ?? []
      return try JSONSerialization.data(withJSONObject: [
        "input": assistantReplay + [
          [
            "encrypted_content": reasoning,
            "summary": ["provider-generated summary"],
            "type": "reasoning",
          ],
          [
            "arguments": #"{"path":"\#(path)"}"#,
            "call_id": callID,
            "name": "file_read",
            "type": "function_call",
          ],
          [
            "call_id": callID,
            "output": fence,
            "type": "function_call_output",
          ],
        ],
        "model": PageEvaluationContract.wireModel,
      ])
    }
    let replayA = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: firstFence,
      assistantText: "I will read the approved input."
    )
    let replayB = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )
    let callIDDrift = try secondRequest(
      callID: "call-provider-b",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )
    let reasoningDrift = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-b",
      path: "input.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )
    let assistantDrift = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: secondFence,
      assistantText: "Different visible commentary."
    )
    let pathDrift = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "other.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )

    // when
    let firstFenceHash = EvaluationHTTPRecorder.normalizedStructureSHA256(firstBody)
    let secondFenceHash = EvaluationHTTPRecorder.normalizedStructureSHA256(secondBody)
    let replayHash = EvaluationHTTPRecorder.normalizedStructureSHA256(replayA)
    let replayBHash = EvaluationHTTPRecorder.normalizedStructureSHA256(replayB)

    // then
    #expect(firstFenceHash == secondFenceHash)
    #expect(
      EvaluationHTTPRecorder.normalizedStructureSHA256(ordinaryA)
        != EvaluationHTTPRecorder.normalizedStructureSHA256(ordinaryB)
    )
    #expect(replayHash == replayBHash)
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(callIDDrift))
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(reasoningDrift))
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(assistantDrift))
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(pathDrift))
  }
}
