import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// Sealing is the one transaction that turns a settled run into evidence. It is idempotent, it
/// reads the surface the run froze at pickup rather than today's, and it refuses every run whose
/// primary facts are not final.
@Suite struct EvidenceSealingTests {
  @Test func secondSealIsANoOp() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let runId = try env.settledBoundRun()

    // when
    let first = try env.learning.sealEvidence(runId: runId, now: env.now)
    let second = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then
    #expect(first == .sealed(eligibility: .eligibleTaskEvidence))
    #expect(second == .alreadySealed)
    #expect(try env.evidenceCount(runId: runId) == 1)
  }

  @Test func sealerIgnoresTerminalRunsWithoutSettlement() throws {
    // given — one settled run and one terminal run whose settlement is still deferred
    let env = try BoundRunEnvironment.make()
    let settled = try env.settledBoundRun()
    let deferred = try env.terminalBoundRunWithoutSettlement()

    // when
    let queue = try env.learning.unsealed(limit: 10)

    // then — the queue selects on settlement, not on terminality
    #expect(queue.contains(settled))
    #expect(queue.contains(deferred) == false)
  }

  @Test func aDelayedSealerDoesNotRefileAnOldRunUnderANewSurface() throws {
    // given — a settled run whose skill set changed before the sweep reached it
    let env = try BoundRunEnvironment.make()
    let runId = try env.settledBoundRun()
    let frozen = try #require(try env.learning.compatibility(runId: runId))
    try env.freezeSurface(runId: runId, skillSetDigest: BoundRunEnvironment.laterSkillSetDigest)

    // when
    _ = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then — the run is filed under the surface it ran on, not the one in force at sealing
    let evidence = try #require(try env.learning.evidence(runId: runId))
    let payload = try #require(evidence.payload)
    #expect(payload.skillSetDigest == frozen.skillSetDigest)
    #expect(payload.skillSetDigest == BoundRunEnvironment.pickupSkillSetDigest)
    #expect(payload.finalOutput == "done")
  }

  @Test func sealedEvidenceCarriesTheRouteTheAnsweringRoundActuallyServed() throws {
    // given — a run that fell back: an earlier attempt billed the configured primary, and the round
    // that produced the owner's answer billed a different route
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    try env.freezeSurface(runId: runId, skillSetDigest: BoundRunEnvironment.pickupSkillSetDigest)
    try env.recordEarlierUsage(runId: runId, model: "openai-compatible/primary")
    let turn = env.assistantTurn(runId: runId, model: "openai-chatgpt/fallback")
    _ = try env.runs.commitAssistantTurn(turn, now: env.now)

    // when
    _ = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then — evidence from another route is not evidence about this one, so the newest usage row
    // wins and the configured route stays a separate field
    let evidence = try #require(try env.learning.evidence(runId: runId))
    let payload = try #require(evidence.payload)
    #expect(payload.terminalRoute == "openai-chatgpt/fallback")
    #expect(payload.configuredRoute == "openai-compatible/test-model")
  }

  @Test func aDeferredSettlementStillRecordsTheRouteOnItsReceipt() throws {
    // given — a cancelled bound run whose in-flight round records its usage after the run is
    // already terminal, which is the whole reason its settlement is deferred
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    try env.freezeSurface(runId: runId, skillSetDigest: BoundRunEnvironment.pickupSkillSetDigest)
    _ = try env.runs.cancelActiveRun(sessionId: env.sessionId, reason: .cancelled, now: env.now)
    try env.recordEarlierUsage(runId: runId, model: "openai-chatgpt/fallback")
    #expect(try env.learning.settleFromLane(runId: runId, now: env.now))

    // when — an owner interruption is not task evidence, so this seals a receipt with no payload
    let outcome = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then — the route is recorded for every sealed run, not only the ones carrying a payload
    #expect(outcome == .sealed(eligibility: .ownerInterruption))
    #expect(try env.terminalRoute(runId: runId) == "openai-chatgpt/fallback")
  }

  @Test func aMissingCompatibilityRowSealsInsufficientEvidenceRatherThanAGuess() throws {
    // given — a settled bound run that never froze its surface
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    _ = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // when
    let outcome = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then
    #expect(outcome == .excluded(.compatibilityUnavailable))
    let evidence = try #require(try env.learning.evidence(runId: runId))
    #expect(evidence.eligibility == .insufficientEvidence)
    #expect(evidence.payload == nil)
  }

  @Test func aStaleEpochClaimWritesAContentFreeTombstone() throws {
    // given — the job moved to a later epoch after this run fired
    let env = try BoundRunEnvironment.make()
    let runId = try env.settledBoundRun()
    try env.advanceJobEpoch()

    // when
    let first = try env.learning.sealEvidence(runId: runId, now: env.now)
    let second = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then — the run is closed once and its evidence never rejoins the loop
    #expect(first == .excluded(.staleEpoch))
    #expect(second == .alreadySealed)
    #expect(try #require(try env.learning.evidence(runId: runId)).payload == nil)
  }

  @Test func anUnboundRunIsATechnicalExclusionWithNoPayload() throws {
    // given — a heartbeat-shaped run with no learning binding
    let env = try BoundRunEnvironment.make()
    let runId = try env.unboundRun()

    // when
    let outcome = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then — there is no job or epoch to file a receipt under, so none is written
    #expect(outcome == .excluded(.legacyUnbound))
    #expect(try env.evidenceCount(runId: runId) == 0)
  }

  @Test func anUnansweredToolCallSealsWithoutAPayload() throws {
    // given — a run that completed with a proposed call no observation row ever answered
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    try env.freezeSurface(runId: runId, skillSetDigest: BoundRunEnvironment.pickupSkillSetDigest)
    try env.proposeUnansweredToolCall(runId: runId)
    _ = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // when
    let outcome = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then — the sealer classifies the transcript it derived, not the terminal cause alone
    #expect(outcome == .sealed(eligibility: .insufficientEvidence))
    #expect(try #require(try env.learning.evidence(runId: runId)).payload == nil)
  }
}
