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
