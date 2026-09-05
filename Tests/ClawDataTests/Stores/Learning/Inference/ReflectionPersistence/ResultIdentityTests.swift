import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension ReflectionPersistenceTests {
  @Test func wrongPhaseProductRollsBackClosureAndSpend() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: started, product: .evaluation(env.verdict())),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — accepting an evaluator product would make the closed result union merely cosmetic
    guard case .unexpected = failure else {
      Issue.record("expected a mapped wrong-phase failure")
      return
    }
    #expect(try env.operationState(started.id) == .started)
    #expect(try env.learningUsage(operationId: started.id).isEmpty)
    #expect(try env.countRows(in: "learning_evaluations") == 2)
  }

  @Test func evaluatorCannotCommitAReflectionProduct() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let reflector = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: reflector)
    let evaluator = try env.startedOperation(try env.evaluatorKey())

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: evaluator, product: .candidate(artifact)),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — without the opposite phase arm, a false-current artifact still closes an evaluator
    guard case .unexpected = failure else {
      Issue.record("expected a mapped wrong-phase failure")
      return
    }
    #expect(try env.operationState(evaluator.id) == .started)
    #expect(try env.learningUsage(operationId: evaluator.id).isEmpty)
  }

  @Test(arguments: ReflectionProductIdentityMismatch.allCases)
  func reflectionFinishRejectsMismatchedProductIdentities(
    _ mismatch: ReflectionProductIdentityMismatch
  ) throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let operation = try env.startReflector(fixture)
    let product = try mismatchedProduct(
      mismatch,
      env: env,
      fixture: fixture,
      operation: operation
    )

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: operation, product: product),
      now: env.now
    )

    // then — dropping one product-to-operation identity check would persist authority from a
    // different trigger, call, schema, origin, or predecessor while still charging this call
    #expect(committed)
    #expect(try env.operationState(operation.id) == .succeeded)
    #expect(try env.learningUsage(operationId: operation.id).count == 1)
    #expect(try env.countRows(in: "learning_candidates") == 0)
    #expect(try env.countRows(in: "learning_decisions") == 0)
  }

  @Test func staleResultClosesAndChargesButPersistsNoArtifact() throws {
    // given — authorization succeeded before the source cutoff advanced
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    try env.advanceFeedbackRevision()

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .candidate(artifact)),
      now: env.now
    )

    // then — dropping the finish-time cutoff check would persist late output against newer state
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.countRows(in: "learning_candidates") == 0)
    #expect(try env.learning.candidateArtifact(digest: artifact.digest) == nil)
  }

  @Test func staleNoCandidateClosesAndChargesWithoutWritingAReceipt() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let result = try env.noCandidate(fixture: fixture, operation: started)
    try env.advanceFeedbackRevision()

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .noCandidate(result)),
      now: env.now
    )

    // then — a stale null result is no more authoritative than a stale replacement
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.countRows(in: "learning_decisions") == 0)
  }
}

enum ReflectionProductIdentityMismatch: CaseIterable, Sendable {
  case candidateOperation
  case candidateCarrier
  case candidateTrigger
  case candidateSchema
  case candidateOrigin
  case candidatePredecessor
  case candidatePredecessorFeedback
  case noCandidateOperation
  case noCandidateCarrier
  case noCandidateTrigger
}

// MARK: - Product Identity Fixtures

private extension ReflectionPersistenceTests {
  func mismatchedProduct(
    _ mismatch: ReflectionProductIdentityMismatch,
    env: BoundRunEnvironment,
    fixture: BoundRunEnvironment.ReflectionFixture,
    operation: ClaimedOperation
  ) throws -> LearningOperationProduct {
    switch mismatch {
    case .candidateOperation, .candidateCarrier, .candidateTrigger, .candidateSchema,
      .candidateOrigin, .candidatePredecessor, .candidatePredecessorFeedback:
      let artifact = try env.candidate(fixture: fixture, operation: operation)
      let manifest = copyManifest(artifact.manifest, productMismatch: mismatch)
      return .candidate(
        try CandidateArtifact(replacement: artifact.replacement, manifest: manifest)
      )
    case .noCandidateOperation, .noCandidateCarrier, .noCandidateTrigger:
      let result = try env.noCandidate(fixture: fixture, operation: operation)
      return .noCandidate(copyNoCandidate(result, mismatch: mismatch))
    }
  }

  func copyManifest(
    _ manifest: CandidateSourceManifest,
    productMismatch: ReflectionProductIdentityMismatch
  ) -> CandidateSourceManifest {
    let predecessorFeedback = CandidateFeedbackSource(
      eventId: 92,
      digest: FeedbackEventDigest(rawValue: "predecessor-feedback"),
      revision: manifest.feedbackRevision,
      subjectKind: .candidate,
      subjectDigest: "predecessor-candidate",
      signal: .candidateApprove
    )
    return CandidateSourceManifest(
      schemaVersion: productMismatch == .candidateSchema
        ? manifest.schemaVersion + 1 : manifest.schemaVersion,
      origin: productMismatch == .candidateOrigin ? .ownerEdit : manifest.origin,
      algorithm: manifest.algorithm,
      jobId: manifest.jobId,
      epoch: manifest.epoch,
      triggerDigest:
        productMismatch == .candidateTrigger
        ? TriggerDigest(rawValue: "different-trigger")
        : manifest.triggerDigest,
      triggerReason: manifest.triggerReason,
      qualifyingIssueCodes: manifest.qualifyingIssueCodes,
      operationId:
        productMismatch == .candidateOperation
        ? LearningOperationID(rawValue: "different-operation")
        : manifest.operationId,
      carrierDigest:
        productMismatch == .candidateCarrier
        ? CarrierDigest(rawValue: "different-carrier")
        : manifest.carrierDigest,
      resultDigest: manifest.resultDigest,
      baseDigest: manifest.baseDigest,
      baseRevision: manifest.baseRevision,
      feedbackRevision: manifest.feedbackRevision,
      evidence: manifest.evidence,
      evaluations: manifest.evaluations,
      feedback: manifest.feedback,
      predecessorCandidate:
        productMismatch == .candidatePredecessor
        ? CandidateDigest(rawValue: "predecessor-candidate")
        : manifest.predecessorCandidate,
      predecessorFeedback:
        productMismatch == .candidatePredecessorFeedback
        ? predecessorFeedback
        : manifest.predecessorFeedback
    )
  }

  func copyNoCandidate(
    _ result: NoCandidateResult,
    mismatch: ReflectionProductIdentityMismatch
  ) -> NoCandidateResult {
    NoCandidateResult(
      algorithm: result.algorithm,
      triggerDigest:
        mismatch == .noCandidateTrigger
        ? TriggerDigest(rawValue: "different-trigger")
        : result.triggerDigest,
      operationId:
        mismatch == .noCandidateOperation
        ? LearningOperationID(rawValue: "different-operation")
        : result.operationId,
      carrierDigest:
        mismatch == .noCandidateCarrier
        ? CarrierDigest(rawValue: "different-carrier")
        : result.carrierDigest,
      resultDigest: result.resultDigest,
      authorization: result.authorization
    )
  }
}
