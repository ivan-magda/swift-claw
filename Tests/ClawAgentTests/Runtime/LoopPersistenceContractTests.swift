import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct LoopPersistenceContractTests {
  private func run(
    _ runtime: AgentRuntime
  ) async throws -> TurnOutcome {
    try await runtime.runTurn(
      runId: 1,
      sessionId: 1,
      chatId: 1,
      buildResult: makeBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
  }

  @Test func intermediateRoundTripsWriteUsageImmediatelyFinalRidesTheCommit() async throws {
    // given — two tool round-trips then a final answer (D6)
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1")]),
      toolCallResponse([fetchProposal(id: "c2")]),
      okResponse(content: "done"),
    ])
    let usageStore = RecordingUsageStore()
    let runtime = makeRuntime(
      provider: provider,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome()),
      usageStore: usageStore
    )

    // when
    let outcome = try await run(runtime)

    // then — exactly the two INTERMEDIATE rows were written; the final row rides TurnResult
    #expect(usageStore.recorded.count == 2)
    let completed = try requireCompleted(outcome.result)
    #expect(completed.usage.promptTokens > 0)
  }

  @Test func usageWriteFailureHaltsProviderCallsAndDegradesAccountingFailed() async throws {
    // given — the first intermediate write fails (non-diskFull)
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1")]),
      okResponse(content: "never reached"),
    ])
    let usageStore = RecordingUsageStore(failOnWrite: 1)
    let runtime = makeRuntime(
      provider: provider,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome()),
      usageStore: usageStore
    )

    // when
    let outcome = try await run(runtime)

    // then — no further provider calls; the pinned degradation; usage nil (§6 — review H2)
    let degraded = try requireDegraded(outcome.result)
    #expect(degraded.kind == .accountingFailed)
    #expect(degraded.usage == nil)
    #expect(await provider.requests.count == 1)
  }

  @Test func usageWriteDiskFullPropagates() async throws {
    // given — the ONLY error runTurn may throw (§6)
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1")]),
      okResponse(),
    ])
    let usageStore = RecordingUsageStore(failOnWrite: 1, thrown: StoreError.diskFull)
    let runtime = makeRuntime(
      provider: provider,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome()),
      usageStore: usageStore
    )

    // when / then
    await #expect(throws: StoreError.diskFull) {
      _ = try await self.run(runtime)
    }
  }

  @Test func everyDispatchGetsOneAuditRowBlockedIncluded() async throws {
    // given — one executed call and one blocked call in the same batch (FR-T1/§6)
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1"), fetchProposal(id: "c2")]),
      okResponse(),
    ])
    let auditLog = RecordingAuditLog()
    let dispatcher = ScriptedDispatcher { call, context in
      if call.id == "c1" {
        return okOutcome()(call, context)
      }
      return ToolDispatchOutcome(
        observation: ToolObservation(
          callId: call.id,
          toolName: call.name,
          content: "blocked",
          status: .blockedArgs,
          ingestedUntrusted: false
        ),
        argsRedacted: "[REDACTED:openai-key]"
      )
    }
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher, auditLog: auditLog)

    // when
    _ = try await run(runtime)

    // then — two rows, the pinned shape: action .toolCall, decision = status rawValue, args redacted
    let events = auditLog.events
    #expect(events.count == 2)
    #expect(events.allSatisfy { event in event.action == .toolCall })
    #expect(events[0].decision == "ok")
    #expect(events[1].decision == "blocked_args")
    #expect(events[1].argsRedacted == "[REDACTED:openai-key]")
    #expect(events[1].tool == "web_fetch")
  }

  @Test func auditWriteFailureLogsAndContinues() async throws {
    // given — audit is observability, not a gate (§6)
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1")]),
      okResponse(content: "finished anyway"),
    ])
    let auditLog = RecordingAuditLog(thrown: StoreError.unexpected("scripted"))
    let runtime = makeRuntime(
      provider: provider,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome()),
      auditLog: auditLog
    )

    // when
    let outcome = try await run(runtime)

    // then — the run completed despite every audit write failing
    #expect(try requireCompleted(outcome.result).content == "finished anyway")
  }

  @Test func auditWriteDiskFullPropagates() async throws {
    // given
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1")]),
      okResponse(),
    ])
    let auditLog = RecordingAuditLog(thrown: StoreError.diskFull)
    let runtime = makeRuntime(
      provider: provider,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome()),
      auditLog: auditLog
    )

    // when / then
    await #expect(throws: StoreError.diskFull) {
      _ = try await self.run(runtime)
    }
  }
}
