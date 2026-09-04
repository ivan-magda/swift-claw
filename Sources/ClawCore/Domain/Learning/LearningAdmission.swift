import Foundation

public enum AdmissionSupport: Sendable, Equatable {
  case recurringIssue
  case ownerCorrection
  case ownerApproval
}

public enum AdmissionRejection: Error, Sendable, Equatable {
  case jobNotRepeatable
  case staleEpoch
  case staleBaseDigest
  case staleBaseRevision
  case staleFeedbackRevision
  case trialAlreadyLive
  case sourceBindingsChanged
  case hardVeto(HardVeto)
  case replacementAlreadyClosed
  case supportUnavailable
  case noOpReplacement
  case secretLeak
  case lessonSet(LessonSetError)
  case invalidOwnerControl
  case unchangedEdit
}

public struct AdmissionReceipt: Sendable, Equatable, Codable {
  public static let kind = "candidate_admission"

  public let candidateDigest: CandidateDigest
  public let replacementDigest: LessonSetDigest
  public let trialId: Int64
  public let generation: Int

  public init(
    candidateDigest: CandidateDigest,
    replacementDigest: LessonSetDigest,
    trialId: Int64,
    generation: Int
  ) {
    self.candidateDigest = candidateDigest
    self.replacementDigest = replacementDigest
    self.trialId = trialId
    self.generation = generation
  }

  enum CodingKeys: String, CodingKey {
    case candidateDigest = "candidate_digest"
    case replacementDigest = "replacement_digest"
    case trialId = "trial_id"
    case generation
  }
}

public enum AdmissionOutcome: Sendable, Equatable {
  case admitted(AdmissionReceipt)
  case awaitingApproval(CandidateArtifact)
  case rejected(AdmissionRejection)
}

public struct CandidateApproval: Sendable, Equatable {
  public let predecessorDigest: CandidateDigest
  public let feedbackEventId: Int64

  public init(predecessorDigest: CandidateDigest, feedbackEventId: Int64) {
    self.predecessorDigest = predecessorDigest
    self.feedbackEventId = feedbackEventId
  }
}

public struct CandidateEdit: Sendable, Equatable {
  public let predecessorDigest: CandidateDigest
  public let feedbackEventId: Int64
  public let payload: Data

  public init(predecessorDigest: CandidateDigest, feedbackEventId: Int64, payload: Data) {
    self.predecessorDigest = predecessorDigest
    self.feedbackEventId = feedbackEventId
    self.payload = payload
  }
}

public enum CandidateReviewState: Sendable, Equatable {
  case admitted
  case awaitingApproval
}

public enum CandidateReviewIdentity {
  private static let domain = "candidate-review/v1"

  public static func digest(candidateDigest: CandidateDigest) -> String {
    SHA256Digest.hex(CanonicalDigestInput.joined([domain, candidateDigest.rawValue]))
  }
}

public struct CandidateReviewNotice: Sendable, Equatable {
  public let candidateDigest: CandidateDigest
  public let state: CandidateReviewState
  public let subjectDigest: String
  public let targets: [NewFeedbackTarget]
  public let chunks: [LearningNoticeChunk]

  public init(
    candidateDigest: CandidateDigest,
    state: CandidateReviewState,
    subjectDigest: String,
    targets: [NewFeedbackTarget],
    chunks: [LearningNoticeChunk]
  ) {
    self.candidateDigest = candidateDigest
    self.state = state
    self.subjectDigest = subjectDigest
    self.targets = targets
    self.chunks = chunks
  }
}

public struct AdmissionValidationContext: Sendable {
  public let currentState: JobLearningState
  public let jobHasRecurrence: Bool
  public let jobStatus: ScheduledJobStatus
  public let hasLiveTrial: Bool
  public let sourceBindingsAreCurrent: Bool
  public let hardVetoes: Set<HardVeto>
  public let replacementAlreadyClosed: Bool
  public let support: AdmissionSupport?
  public let requiresSupport: Bool
  public let permitsClosedReplacement: Bool
  public let redactor: SecretRedactor

  public init(
    currentState: JobLearningState,
    jobHasRecurrence: Bool,
    jobStatus: ScheduledJobStatus,
    hasLiveTrial: Bool,
    sourceBindingsAreCurrent: Bool,
    hardVetoes: Set<HardVeto>,
    replacementAlreadyClosed: Bool,
    support: AdmissionSupport?,
    requiresSupport: Bool = true,
    permitsClosedReplacement: Bool = false,
    redactor: SecretRedactor
  ) {
    self.currentState = currentState
    self.jobHasRecurrence = jobHasRecurrence
    self.jobStatus = jobStatus
    self.hasLiveTrial = hasLiveTrial
    self.sourceBindingsAreCurrent = sourceBindingsAreCurrent
    self.hardVetoes = hardVetoes
    self.replacementAlreadyClosed = replacementAlreadyClosed
    self.support = support
    self.requiresSupport = requiresSupport
    self.permitsClosedReplacement = permitsClosedReplacement
    self.redactor = redactor
  }
}

public enum AdmissionValidator {
  public static func validate(
    candidate: CandidateArtifact,
    context: AdmissionValidationContext
  ) -> AdmissionRejection? {
    let manifest = candidate.manifest
    let state = context.currentState
    guard context.jobHasRecurrence, [.active, .paused].contains(context.jobStatus) else {
      return .jobNotRepeatable
    }
    guard manifest.jobId == state.jobId, manifest.epoch == state.epoch else {
      return .staleEpoch
    }
    guard manifest.baseDigest == state.stableDigest else {
      return .staleBaseDigest
    }
    guard manifest.baseRevision == state.stableRevision else {
      return .staleBaseRevision
    }
    guard manifest.feedbackRevision == state.feedbackRevision else {
      return .staleFeedbackRevision
    }
    guard context.hasLiveTrial == false else {
      return .trialAlreadyLive
    }
    guard context.sourceBindingsAreCurrent else {
      return .sourceBindingsChanged
    }
    if let veto = HardVeto.allCases.first(where: context.hardVetoes.contains) {
      return .hardVeto(veto)
    }
    guard candidate.replacement.digest != state.stableDigest else {
      return .noOpReplacement
    }
    guard context.permitsClosedReplacement || context.replacementAlreadyClosed == false else {
      return .replacementAlreadyClosed
    }
    guard context.requiresSupport == false || context.support != nil else {
      return .supportUnavailable
    }
    guard containsSecret(candidate.replacement, redactor: context.redactor) == false else {
      return .secretLeak
    }
    return nil
  }

  public static func validatedReplacement(
    jobId: Int64,
    lessons: [String],
    redactor: SecretRedactor
  ) -> Result<LessonSet, AdmissionRejection> {
    let replacement: LessonSet
    do {
      replacement = try LessonSet.canonical(jobId: jobId, lessons: lessons)
    } catch {
      return .failure(.lessonSet(error))
    }
    guard containsSecret(replacement, redactor: redactor) == false else {
      return .failure(.secretLeak)
    }
    return .success(replacement)
  }

  private static func containsSecret(
    _ replacement: LessonSet,
    redactor: SecretRedactor
  ) -> Bool {
    if replacement.lessons.contains(where: { lesson in
      redactor.redact(lesson) != lesson
    }) {
      return true
    }
    // swiftlint:disable:next optional_data_string_conversion
    let canonical = String(decoding: replacement.canonicalBytes, as: UTF8.self)
    return redactor.redact(canonical) != canonical
  }
}

public enum CandidateSuccessorRules {
  public static func approval(
    predecessor: CandidateArtifact,
    control: CandidateFeedbackSource,
    feedbackRevision: FeedbackRevision,
    effectiveFeedback: [CandidateFeedbackSource]
  ) throws(AdmissionRejection) -> CandidateArtifact {
    try successor(
      predecessor: predecessor,
      replacement: predecessor.replacement,
      intent: SuccessorIntent(
        origin: .ownerApproval,
        expectedSignal: .candidateApprove,
        control: control,
        feedbackRevision: feedbackRevision,
        effectiveFeedback: effectiveFeedback
      )
    )
  }

  public static func edit(
    predecessor: CandidateArtifact,
    replacement: LessonSet,
    control: CandidateFeedbackSource,
    feedbackRevision: FeedbackRevision,
    effectiveFeedback: [CandidateFeedbackSource]
  ) throws(AdmissionRejection) -> CandidateArtifact {
    guard replacement.digest != predecessor.replacement.digest else {
      throw .unchangedEdit
    }
    return try successor(
      predecessor: predecessor,
      replacement: replacement,
      intent: SuccessorIntent(
        origin: .ownerEdit,
        expectedSignal: .candidateEdit,
        control: control,
        feedbackRevision: feedbackRevision,
        effectiveFeedback: effectiveFeedback
      )
    )
  }
}

// MARK: - Successor Construction

private extension CandidateSuccessorRules {
  struct SuccessorIntent {
    let origin: CandidateOrigin
    let expectedSignal: OwnerSignal
    let control: CandidateFeedbackSource
    let feedbackRevision: FeedbackRevision
    let effectiveFeedback: [CandidateFeedbackSource]
  }

  static func successor(
    predecessor: CandidateArtifact,
    replacement: LessonSet,
    intent: SuccessorIntent
  ) throws(AdmissionRejection) -> CandidateArtifact {
    guard
      intent.control.subjectKind == .candidate,
      intent.control.subjectDigest == predecessor.digest.rawValue,
      intent.control.signal == intent.expectedSignal,
      intent.control.revision <= intent.feedbackRevision,
      intent.feedbackRevision >= predecessor.manifest.feedbackRevision
    else {
      throw .invalidOwnerControl
    }
    let source = predecessor.manifest
    let manifest = CandidateSourceManifest(
      origin: intent.origin,
      algorithm: source.algorithm,
      jobId: source.jobId,
      epoch: source.epoch,
      triggerDigest: source.triggerDigest,
      triggerReason: source.triggerReason,
      qualifyingIssueCodes: source.qualifyingIssueCodes,
      operationId: source.operationId,
      carrierDigest: source.carrierDigest,
      resultDigest: source.resultDigest,
      baseDigest: source.baseDigest,
      baseRevision: source.baseRevision,
      feedbackRevision: intent.feedbackRevision,
      evidence: source.evidence,
      evaluations: source.evaluations,
      feedback: intent.effectiveFeedback,
      predecessorCandidate: predecessor.digest,
      predecessorFeedback: intent.control
    )
    do {
      return try CandidateArtifact(replacement: replacement, manifest: manifest)
    } catch {
      throw .invalidOwnerControl
    }
  }
}

public enum CandidateEditPayload {
  // Invalid JSON and a valid empty lesson list are different admission outcomes.
  // swiftlint:disable:next discouraged_optional_collection
  public static func decode(_ bytes: Data) -> [String]? {
    (try? JSONDecoder().decode(ReflectorOutput.Candidate.self, from: bytes))?.lessons
  }
}
