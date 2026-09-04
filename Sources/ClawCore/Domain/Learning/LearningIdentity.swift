import Foundation

/// The versioned policy a candidate, trial or decision receipt was created under. Records carry it
/// so a later algorithm version never silently reinterprets work frozen by an earlier one.
public struct LearningAlgorithm: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  // swiftlint:disable:next identifier_name
  public static let v1 = LearningAlgorithm(rawValue: "scheduled-learning/v1")
}

/// Digest of a `LessonSet`'s content — `{"schema_version": 1, "lessons": [...]}`, never the owning
/// job id. Identity in storage is the pair `(jobId, digest)`.
public struct LessonSetDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Digest of one candidate record. Stays distinct from `LessonSetDigest` — a candidate's own record
/// digest and the replacement lesson-set digest it proposes are different values, and the compiler
/// should refuse to swap them.
public struct CandidateDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Digest of the canonical typed source manifest, distinct from the candidate record that also
/// binds replacement bytes and origin.
public struct CandidateSourceManifestDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// SHA-256 over the canonical bytes of what a job asks for. Stays distinct from the lesson-set and
/// candidate digests it sits beside in a binding, so the compiler refuses to swap them. Two runs
/// are comparable evidence about the same task only while this value is unchanged: an edited prompt
/// or a moved schedule is a different task, not more evidence about the old one.
public struct JobDefinitionDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func of(
    label: String,
    prompt: String,
    recurrenceJSON: String?,
    timezone: String
  ) throws -> JobDefinitionDigest {
    let payload = Payload(
      label: label,
      prompt: prompt,
      recurrence: recurrenceJSON,
      timezone: timezone
    )
    return JobDefinitionDigest(
      rawValue: SHA256Digest.hex(try CanonicalJSON.data(encoding: payload))
    )
  }

  private struct Payload: Codable {
    let label: String
    let prompt: String
    let recurrence: String?
    let timezone: String
  }
}

/// Digest of one run's sealed evidence — over the canonical payload the evaluator reads, or over
/// the compact receipt when there is no payload. Stays distinct from the evaluation digest that
/// later references it.
public struct EvidenceDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Digest of one frozen evaluation used as reflection evidence.
public struct EvaluationDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Digest of one exact append-only owner-feedback event. The row id locates the dependency; this
/// digest binds every value whose later verification decides whether that dependency is unchanged.
public struct FeedbackEventDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func of(  // swiftlint:disable:this function_parameter_count
    eventId: Int64,
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String,
    signal: OwnerSignal,
    payload: String?,
    actor: AuditActor,
    transportUpdateId: Int64?,
    revision: FeedbackRevision,
    supersedes: Int64?,
    occurredAtEpochSecond: Int64
  ) throws -> FeedbackEventDigest {
    let event = EventProjection(
      eventId: eventId,
      jobId: jobId,
      epoch: epoch.value,
      subjectKind: subjectKind.rawValue,
      subjectDigest: subjectDigest,
      signal: signal.rawValue,
      payload: payload,
      actor: actor.rawValue,
      transportUpdateId: transportUpdateId,
      revision: revision.value,
      supersedes: supersedes,
      occurredAtEpochSecond: occurredAtEpochSecond
    )
    let bytes = try CanonicalJSON.data(encoding: event)
    let framed = CanonicalDigestInput.joined([
      "feedback-event/v1", bytes.base64EncodedString(),
    ])
    return FeedbackEventDigest(rawValue: SHA256Digest.hex(framed))
  }

  private struct EventProjection: Encodable {
    let eventId: Int64
    let jobId: Int64
    let epoch: Int64
    let subjectKind: String
    let subjectDigest: String
    let signal: String
    let payload: String?
    let actor: String
    let transportUpdateId: Int64?
    let revision: Int64
    let supersedes: Int64?
    let occurredAtEpochSecond: Int64

    enum CodingKeys: String, CodingKey {
      case eventId = "event_id"
      case jobId = "job_id"
      case epoch = "learning_epoch"
      case subjectKind = "subject_kind"
      case subjectDigest = "subject_digest"
      case signal
      case payload
      case actor
      case transportUpdateId = "transport_update_id"
      case revision = "feedback_revision"
      case supersedes
      case occurredAtEpochSecond = "occurred_at"
    }
  }
}

/// Monotonic per job. Epoch 1 on two jobs is two unrelated epochs, so every carrier of this value
/// carries its `job_id` alongside it.
public struct LearningEpoch: Sendable, Hashable, Comparable, Codable {
  public let value: Int64

  public init(_ value: Int64) {
    self.value = value
  }

  public static func < (lhs: LearningEpoch, rhs: LearningEpoch) -> Bool {
    lhs.value < rhs.value
  }

  public func next() -> LearningEpoch {
    LearningEpoch(value + 1)
  }
}

/// Marks which frozen version of the current stable lesson set an evidence window or trial was
/// computed against, so a stable change can never be silently reinterpreted after the fact.
public struct StableRevision: Sendable, Hashable, Comparable, Codable {
  public let value: Int64

  public init(_ value: Int64) {
    self.value = value
  }

  public static func < (lhs: StableRevision, rhs: StableRevision) -> Bool {
    lhs.value < rhs.value
  }

  public func next() -> StableRevision {
    StableRevision(value + 1)
  }
}

/// Marks which frozen version of the append-only owner-feedback log a candidate, approval or
/// decision was computed against, so a later feedback event can never be silently folded into an
/// already-frozen source manifest.
public struct FeedbackRevision: Sendable, Hashable, Comparable, Codable {
  public let value: Int64

  public init(_ value: Int64) {
    self.value = value
  }

  public static func < (lhs: FeedbackRevision, rhs: FeedbackRevision) -> Bool {
    lhs.value < rhs.value
  }

  public func next() -> FeedbackRevision {
    FeedbackRevision(value + 1)
  }
}

/// Digest of the whole surface two runs must share before their verdicts may be counted as
/// evidence about the same question: the surface the run was picked up on, the versions the sealer
/// stamped, and the evaluator's own route and versions. Frozen onto every evaluation, so a later
/// change to any of them opens a new comparison window instead of silently reinterpreting old
/// verdicts.
public struct CompatibilityDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// SHA-256 identity of one frozen reflection question.
public struct TriggerDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Digest of one `LearningOperationKey`. The stored claim key: `learning_operations` has no
/// columns for the prompt, schema and rubric versions the key covers, so this is the only value a
/// unique index can hold the "one live attempt per key" rule on.
public struct LearningOperationKeyDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// One durable `learning_operations` row. Its shape is the key digest and the attempt generation,
/// so a superseding attempt is visibly the same question asked again rather than a new one.
public struct LearningOperationID: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(key: LearningOperationKeyDigest, attemptGeneration: Int) {
    rawValue = "\(key.rawValue):\(attemptGeneration)"
  }
}

/// Digest of the exact carrier bytes one learning call sends. Stays distinct from the source digest
/// beside it in an authorization: one names what the carrier was built from, the other what it
/// became after fencing and scrubbing.
public struct CarrierDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Digest of the exact closed reflector reply after fence removal. It is source provenance, not
/// candidate identity: a null result has one too, and a candidate digest also binds its manifest.
public struct ReflectionResultDigest: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func of(_ bytes: Data) -> ReflectionResultDigest {
    let framed = CanonicalDigestInput.joined([
      "reflection-result/v1", bytes.base64EncodedString(),
    ])
    return ReflectionResultDigest(rawValue: SHA256Digest.hex(framed))
  }
}
