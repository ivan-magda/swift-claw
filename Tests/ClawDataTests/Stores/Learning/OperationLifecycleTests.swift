import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// The four transactions that decide whether one logical inference is paid for exactly once: the
/// durable claim, the single authorize-and-start, the result commit, and the boot pass that has to
/// tell "a call may have gone out" from "durable state proves it did not".
@Suite struct OperationLifecycleTests {
  @Test func onlyOneAttemptGenerationIsCurrent() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let key = try env.evaluatorKey()
    let first = try #require(try env.learning.claimOperation(key, now: env.now))

    // when — a second worker claims the same logical key
    let second = try env.learning.claimOperation(key, now: env.now)

    // then
    #expect(second == nil)
    #expect(first.attemptGeneration == 1)
  }

  @Test func aResultCommitsOnlyAgainstAStartedOperation() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let claimed = try env.claim(try env.evaluatorKey())

    // when — a result arrives without the start transaction having run
    let committed = try env.learning.finishOperation(env.result(for: claimed.id), now: env.now)

    // then
    #expect(committed == false)
    #expect(try env.operationState(claimed.id) == .claimed)
    #expect(try env.learningUsage(operationId: claimed.id).isEmpty)
  }

  @Test func twoWorkersCannotBothPassTheBudgetGate() async throws {
    // given — headroom for exactly one learning call
    let env = try BoundRunEnvironment.make()
    let oneCallCostUSD = 0.10
    let claims = [try env.claim(try env.evaluatorKey()), try env.claim(try env.evaluatorKey())]
    // After the claims, never before: each one seals a settled run, and that run's own spend is
    // in the same proactive pool the cap is drawn from.
    let capUSD = try env.proactiveSpentUSD() + oneCallCostUSD
    let authorizations = claims.map { claim in
      env.authorization(
        for: claim,
        estimatedCostUSD: oneCallCostUSD,
        proactiveCapUSD: capUSD
      )
    }
    let learning = env.learning
    let now = env.now

    // when — both authorize concurrently
    let outcomes = try await withThrowingTaskGroup(of: AuthorizeOutcome.self) { group in
      for authorization in authorizations {
        group.addTask {
          try learning.authorizeAndStartOperation(authorization, now: now)
        }
      }
      var collected: [AuthorizeOutcome] = []
      for try await outcome in group {
        collected.append(outcome)
      }
      return collected
    }

    // then — exactly one reaches started; the other is a terminal no-call
    #expect(
      outcomes.filter { outcome in
        outcome == .started
      }
      .count == 1
    )
    #expect(outcomes.contains(.deniedNoCall(.budgetDenied)))
  }

  @Test func aBudgetDenialClosesTheOperationAndReservesNothing() throws {
    // given — a proactive pool with no headroom left at all
    let env = try BoundRunEnvironment.make()
    let key = try env.evaluatorKey()
    let claimed = try env.claim(key)
    let exhausted = try env.proactiveSpentUSD()

    // when
    let outcome = try env.learning.authorizeAndStartOperation(
      env.authorization(for: claimed, estimatedCostUSD: 0.10, proactiveCapUSD: exhausted),
      now: env.now
    )

    // then — terminal, unreserved, and never requeued
    #expect(outcome == .deniedNoCall(.budgetDenied))
    #expect(try env.operationState(claimed.id) == .failedNoCall)
    #expect(try env.failureCode(claimed.id) == .budgetDenied)
    #expect(try env.reservation(claimed.id) == BoundRunEnvironment.closedReservation)
    #expect(try env.providerCallID(claimed.id) == nil)
    #expect(try env.learning.claimOperation(key, now: env.now) == nil)
  }

  @Test func aCarrierDenialClosesTheOperationAndLeavesTheReceipt() throws {
    // given — the privacy verdict recomputed over the carrier refuses it
    let env = try BoundRunEnvironment.make()
    let evidence = try env.sealedEvidence()
    let claimed = try env.claim(env.evaluatorKey(for: evidence))
    let denied = CarrierAuthorization(
      sourceDigest: claimed.key.sourceDigest,
      digest: CarrierDigest(rawValue: "carrier-denied"),
      isPermitted: false
    )

    // when
    let outcome = try env.learning.authorizeAndStartOperation(
      env.authorization(for: claimed, carrier: denied),
      now: env.now
    )

    // then
    #expect(outcome == .deniedNoCall(.carrierPolicyDenied))
    #expect(try env.operationState(claimed.id) == .failedNoCall)
    #expect(try env.failureCode(claimed.id) == .carrierPolicyDenied)
    #expect(try env.learning.evidence(runId: evidence.runId) == evidence)
  }

  @Test func aCarrierBuiltFromAnotherSourceIsRefused() throws {
    // given — a carrier assembled from a different run's evidence than the claim names
    let env = try BoundRunEnvironment.make()
    let claimed = try env.claim(try env.evaluatorKey())
    let elsewhere = try env.sealedEvidence()
    let mismatched = CarrierAuthorization(
      sourceDigest: elsewhere.digest.rawValue,
      digest: CarrierDigest(rawValue: "carrier-elsewhere"),
      isPermitted: true
    )

    // when
    let outcome = try env.learning.authorizeAndStartOperation(
      env.authorization(for: claimed, carrier: mismatched),
      now: env.now
    )

    // then
    #expect(outcome == .deniedNoCall(.carrierPolicyDenied))
    #expect(try env.operationState(claimed.id) == .failedNoCall)
  }

  @Test func anEpochTheJobMovedPastAuthorizesNothing() throws {
    // given — the job re-epoched between the claim and the network handoff
    let env = try BoundRunEnvironment.make()
    let claimed = try env.claim(try env.evaluatorKey())
    try env.advanceJobEpoch()

    // when
    let outcome = try env.learning.authorizeAndStartOperation(
      env.authorization(for: claimed),
      now: env.now
    )

    // then — no call, no reservation, and no terminal policy verdict the operation never earned
    #expect(outcome == .superseded)
    #expect(try env.operationState(claimed.id) == .claimed)
    #expect(try env.providerCallID(claimed.id) == nil)
  }

  @Test func learningSpendReachesTheProactiveTotal() throws {
    // given — a finished evaluator operation on a scheduled job
    let env = try BoundRunEnvironment.make()
    let started = try env.startedOperation(try env.evaluatorKey())
    let before = try env.proactiveSpentUSD()

    // when
    let committed = try env.learning.finishOperation(
      env.result(for: started.id, costUSD: 0.25),
      now: env.now
    )
    let proactive = try env.usage.todayTokensAndCost(
      origins: RunOrigin.proactiveOrigins,
      now: env.now
    )

    // then — a null run_id with no learning scope is invisible to the origin JOIN
    #expect(committed)
    #expect(abs(proactive.costUSD - before - 0.25) < 0.000_001)
    #expect(try env.learningUsage(operationId: started.id).first?.jobId == env.jobId)
  }

  @Test func aDuplicateResultCannotCloseTheReservationTwice() throws {
    // given — a started operation whose result already committed
    let env = try BoundRunEnvironment.make()
    let started = try env.startedOperation(try env.evaluatorKey())
    #expect(try env.learning.finishOperation(env.result(for: started.id), now: env.now))

    // when — the same result is presented again
    let second = try env.learning.finishOperation(env.result(for: started.id), now: env.now)

    // then
    #expect(second == false)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.reservation(started.id) == BoundRunEnvironment.closedReservation)
  }

  @Test func bootReconcilesStartedAndClaimedDifferently() throws {
    // given — a prior process left one operation started and one merely claimed
    let env = try BoundRunEnvironment.make()
    let startedKey = try env.evaluatorKey()
    let started = try env.startedOperation(startedKey)
    let claimed = try env.claim(try env.evaluatorKey())

    // when
    let result = try env.learning.reconcileOperationsAtBoot(now: env.now)

    // then — a started attempt is ambiguous at the network boundary; a claimed one provably is not
    #expect(result.interrupted == 1)
    #expect(result.returnedToClaimable == 1)
    #expect(try env.operationState(started.id) == .interruptedUnknown)
    #expect(try env.operationState(claimed.id) == .pending)

    // when — a later worker claims the interrupted operation's key again
    let retry = try env.claim(startedKey)

    // then — a new generation, an explicit supersedes edge, and never the paid call id
    #expect(retry.attemptGeneration == 2)
    #expect(retry.supersedes == started.id)
    #expect(try env.providerCallID(retry.id) == nil)
    #expect(try env.providerCallID(started.id) != nil)
  }

  @Test func aClaimedOperationBootReturnsToClaimableKeepsItsGeneration() throws {
    // given — a crash between the claim and the authorization
    let env = try BoundRunEnvironment.make()
    let key = try env.evaluatorKey()
    let claimed = try env.claim(key)
    _ = try env.learning.reconcileOperationsAtBoot(now: env.now)

    // when
    let retry = try env.claim(key)

    // then — the same row, re-claimed: no call was ever authorized under it
    #expect(retry.id == claimed.id)
    #expect(retry.attemptGeneration == 1)
    #expect(try env.operationState(claimed.id) == .claimed)
  }

  @Test func bootChargesAnInterruptedCallUnderItsSavedCallID() throws {
    // given — a started operation holding an open reservation
    let env = try BoundRunEnvironment.make()
    let started = try env.startedOperation(try env.evaluatorKey())
    let callID = try #require(try env.providerCallID(started.id))
    let reserved = try #require(try env.reservation(started.id))

    // when
    _ = try env.learning.reconcileOperationsAtBoot(now: env.now)

    // then — the estimate becomes a conservative charge under the id the call was sent with
    let rows = try env.learningUsage(operationId: started.id)
    #expect(rows.count == 1)
    #expect(rows.first?.providerCallID == callID)
    #expect(rows.first?.jobId == env.jobId)
    #expect(rows.first?.runId == nil)
    #expect(rows.first?.costUSD == reserved.costUSD)
    #expect(try env.reservation(started.id) == BoundRunEnvironment.closedReservation)
  }

  @Test func evidenceTheEvaluatorMayNotReadIsNotClaimable() throws {
    // given — a bound run that ended in provider failure, not task evidence
    let env = try BoundRunEnvironment.make()
    let evidence = try env.ineligibleSealedEvidence()

    // when
    let claimed = try env.learning.claimOperation(
      env.evaluatorKey(for: evidence),
      now: env.now
    )

    // then
    #expect(evidence.eligibility == .transientInfrastructureFailure)
    #expect(claimed == nil)
  }

  @Test func alreadyEvaluatedEvidenceIsNotClaimable() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let evidence = try env.sealedEvidence()
    try env.recordEvaluation(of: evidence)

    // when
    let claimed = try env.learning.claimOperation(
      env.evaluatorKey(for: evidence),
      now: env.now
    )

    // then
    #expect(claimed == nil)
  }

  @Test func aKeyFromASupersededEpochIsNotClaimable() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let key = try env.evaluatorKey()
    try env.advanceJobEpoch()

    // when
    let claimed = try env.learning.claimOperation(key, now: env.now)

    // then
    #expect(claimed == nil)
  }
}
