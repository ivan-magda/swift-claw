import Foundation

private struct ByteExactIssueCode: Hashable, Comparable {
  let value: String
  private let bytes: [UInt8]

  init(_ value: String) {
    self.value = value
    bytes = Array(value.utf8)
  }

  static func == (lhs: ByteExactIssueCode, rhs: ByteExactIssueCode) -> Bool {
    lhs.bytes == rhs.bytes
  }

  static func < (lhs: ByteExactIssueCode, rhs: ByteExactIssueCode) -> Bool {
    lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
  }

  func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

/// One completed compatible evaluation after owner precedence has been frozen at a revision.
public struct EffectiveEvaluation: Sendable, Equatable {
  public let runID: Int64
  public let jobID: Int64
  public let epoch: LearningEpoch
  public let stableDigest: LessonSetDigest
  public let evidenceDigest: EvidenceDigest
  public let compatibility: CompatibilityDigest
  public let occurrenceAt: Date
  public let evaluatorCompletedAt: Date
  public let trialID: Int64?
  public let outcome: EffectiveOutcome
  public let feedbackRevision: FeedbackRevision

  public init(  // swiftlint:disable:this function_parameter_count
    runID: Int64,
    jobID: Int64,
    epoch: LearningEpoch,
    stableDigest: LessonSetDigest,
    evidenceDigest: EvidenceDigest,
    compatibility: CompatibilityDigest,
    occurrenceAt: Date,
    evaluatorCompletedAt: Date,
    trialID: Int64?,
    outcome: EffectiveOutcome,
    feedbackRevision: FeedbackRevision
  ) {
    self.runID = runID
    self.jobID = jobID
    self.epoch = epoch
    self.stableDigest = stableDigest
    self.evidenceDigest = evidenceDigest
    self.compatibility = compatibility
    self.occurrenceAt = occurrenceAt
    self.evaluatorCompletedAt = evaluatorCompletedAt
    self.trialID = trialID
    self.outcome = outcome
    self.feedbackRevision = feedbackRevision
  }
}

public enum EvidenceWindow {
  public static let maximumCount = 5
  public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

  /// Selects the stable evidence snapshot for one compatibility digest at an immutable cutoff.
  public static func select(
    from evaluations: [EffectiveEvaluation],
    compatibility: CompatibilityDigest,
    cutoff: Date
  ) -> [EffectiveEvaluation] {
    let oldestOccurrence = cutoff.addingTimeInterval(-maximumAge)
    let ordered = evaluations.filter { evaluation in
      evaluation.compatibility == compatibility && evaluation.trialID == nil
        && evaluation.occurrenceAt >= oldestOccurrence && evaluation.occurrenceAt <= cutoff
        && evaluation.evaluatorCompletedAt <= cutoff
    }.sorted(by: occursBefore)
    return Array(ordered.suffix(maximumCount))
  }
}

// MARK: - Ordering

private extension EvidenceWindow {
  static func occursBefore(_ lhs: EffectiveEvaluation, _ rhs: EffectiveEvaluation) -> Bool {
    if lhs.occurrenceAt != rhs.occurrenceAt {
      return lhs.occurrenceAt < rhs.occurrenceAt
    }
    return lhs.runID < rhs.runID
  }
}

public enum LearningTriggerReason: String, Sendable, Equatable, Codable {
  case recurringIssue = "recurring_issue"
  case ownerCorrection = "owner_correction"
}

/// The complete idempotency identity for one logical reflector operation.
public struct TriggerIdentity: Sendable, Equatable {
  public let jobID: Int64
  public let epoch: LearningEpoch
  public let algorithm: LearningAlgorithm
  public let stableDigest: LessonSetDigest
  public let evidenceDigests: [EvidenceDigest]
  public let feedbackRevision: FeedbackRevision
  public let issueCodes: [String]
  public let reason: LearningTriggerReason

  public init(
    jobID: Int64,
    epoch: LearningEpoch,
    algorithm: LearningAlgorithm,
    stableDigest: LessonSetDigest,
    evidenceDigests: [EvidenceDigest],
    feedbackRevision: FeedbackRevision,
    issueCodes: [String],
    reason: LearningTriggerReason
  ) {
    self.jobID = jobID
    self.epoch = epoch
    self.algorithm = algorithm
    self.stableDigest = stableDigest
    self.evidenceDigests = evidenceDigests
    self.feedbackRevision = feedbackRevision
    self.issueCodes = issueCodes.map(ByteExactIssueCode.init).sorted().map(\.value)
    self.reason = reason
  }

  public var digest: TriggerDigest {
    let evidenceFields = evidenceDigests.map { digest in
      Self.lengthPrefixed(digest.rawValue)
    }
    let issueFields = issueCodes.map(Self.lengthPrefixed)
    let fields =
      [
        Self.canonicalPrefix,
        String(jobID),
        String(epoch.value),
        algorithm.rawValue,
        stableDigest.rawValue,
        String(evidenceFields.count),
      ] + evidenceFields + [String(feedbackRevision.value), String(issueFields.count)] + issueFields
    return TriggerDigest(rawValue: SHA256Digest.hex(CanonicalDigestInput.joined(fields)))
  }

  private static let canonicalPrefix = "learning-trigger/v1"

  private static func lengthPrefixed(_ field: String) -> String { "\(field.utf8.count):\(field)" }
}

public enum LearningTrigger {
  public static let recurringRunThreshold = 2

  public static func detect(
    window: [EffectiveEvaluation],
    corrections: [FeedbackEvent],
    trialIsOpen: Bool = false
  ) -> TriggerIdentity? {
    guard trialIsOpen == false, let first = window.first else {
      return nil
    }
    let eligibleRunIDs = Set(window.map(\.runID))
    var signalsByRun: [Int64: [FeedbackEvent]] = [:]
    for event in corrections {
      guard let runID = event.runID, eligibleRunIDs.contains(runID) else {
        continue
      }
      signalsByRun[runID, default: []].append(event)
    }
    let effectiveCorrections = signalsByRun.values.compactMap { signals in
      let winner = FeedbackEvent.latestUnsupersededResult(in: signals)
      return winner?.signal == .resultCorrection ? winner : nil
    }
    let issueCodes = qualifyingIssueCodes(in: window)
    let reason: LearningTriggerReason
    if effectiveCorrections.isEmpty == false {
      reason = .ownerCorrection
    } else if issueCodes.isEmpty == false {
      reason = .recurringIssue
    } else {
      return nil
    }

    let highestEvaluationRevision = window.map(\.feedbackRevision).max() ?? FeedbackRevision(0)
    let highestCorrectionRevision = effectiveCorrections.map(\.revision).max()
    let feedbackRevision = max(
      highestEvaluationRevision,
      highestCorrectionRevision ?? FeedbackRevision(0)
    )
    return TriggerIdentity(
      jobID: first.jobID,
      epoch: first.epoch,
      algorithm: .v1,
      stableDigest: first.stableDigest,
      evidenceDigests: window.map(\.evidenceDigest),
      feedbackRevision: feedbackRevision,
      issueCodes: issueCodes,
      reason: reason
    )
  }
}

// MARK: - Recurrence

private extension LearningTrigger {
  static func qualifyingIssueCodes(in window: [EffectiveEvaluation]) -> [String] {
    var runsByCode: [ByteExactIssueCode: Set<Int64>] = [:]
    for evaluation in window {
      guard case .negative(let issueCodes) = evaluation.outcome else {
        continue
      }
      for issueCode in Set(issueCodes.map(ByteExactIssueCode.init)) {
        runsByCode[issueCode, default: []].insert(evaluation.runID)
      }
    }
    return runsByCode.compactMap { issueCode, runIDs in
      runIDs.count >= recurringRunThreshold ? issueCode : nil
    }.sorted().map(\.value)
  }
}
