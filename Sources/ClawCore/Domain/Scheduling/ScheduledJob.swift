import Foundation

/// Which pathway created a run. The single discriminator driving reduced privilege, the
/// proactive budget, context assembly, and doctor metrics; persisted via rawValue in
/// `runs.origin`.
public enum RunOrigin: String, Sendable, Equatable {
  case interactive
  case scheduled
  case heartbeat

  /// True for the origins that run with no owner present (a scheduled job or heartbeat fire) —
  /// the pair every proactive gate (budget, prompt selection, context isolation) keys on.
  public var isProactive: Bool {
    self != .interactive
  }
}

/// The scheduled-job status FSM. `completed`/`cancelled` are terminal; terminal rows
/// keep `next_occurrence = NULL` so the ticker's partial index never sees them.
public enum ScheduledJobStatus: String, Sendable, Equatable {
  case active = "ACTIVE"
  case paused = "PAUSED"
  case completed = "COMPLETED"
  case cancelled = "CANCELLED"
}

/// The stored recurrence wrapper: `{"schema_version":1,"rule":<RecurrenceRule JSON>}`.
public struct RecurrenceEnvelope: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let rule: Calendar.RecurrenceRule

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case rule
  }

  public init(schemaVersion: Int, rule: Calendar.RecurrenceRule) {
    self.schemaVersion = schemaVersion
    self.rule = rule
  }

  /// The pinned storage encoding. `.sortedKeys` makes the stored JSON deterministic, which is
  /// what gives the byte-for-byte round-trip tripwire its teeth.
  public func encodedJSON() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // JSONEncoder output is always valid UTF-8, so the failable init's nil branch is unreachable.
    return String(data: try encoder.encode(self), encoding: .utf8) ?? ""
  }

  public static func decode(fromJSON json: String) throws -> RecurrenceEnvelope {
    try JSONDecoder().decode(RecurrenceEnvelope.self, from: Data(json.utf8))
  }
}

/// One row of `scheduled_jobs`.
public struct ScheduledJob: Sendable, Equatable {
  public let id: Int64
  public let ownerChatId: Int64
  public let label: String
  public let prompt: String
  public let recurrence: RecurrenceEnvelope?  // nil ⇔ one-shot
  public let timezone: String  // IANA identifier
  public let nextOccurrence: Date?  // nil once terminal
  public let lastFiredAt: Date?
  public let status: ScheduledJobStatus
  public let sessionId: Int64?  // nil until first fire
  public let createdTs: Date  // row creation time (house convention)
  public let updatedTs: Date

  public init(
    id: Int64,
    ownerChatId: Int64,
    label: String,
    prompt: String,
    recurrence: RecurrenceEnvelope?,
    timezone: String,
    nextOccurrence: Date?,
    lastFiredAt: Date?,
    status: ScheduledJobStatus,
    sessionId: Int64?,
    createdTs: Date,
    updatedTs: Date
  ) {
    self.id = id
    self.ownerChatId = ownerChatId
    self.label = label
    self.prompt = prompt
    self.recurrence = recurrence
    self.timezone = timezone
    self.nextOccurrence = nextOccurrence
    self.lastFiredAt = lastFiredAt
    self.status = status
    self.sessionId = sessionId
    self.createdTs = createdTs
    self.updatedTs = updatedTs
  }
}

/// The arm-time insert payload. `ownerChatId` is set in code from the arming chat — never
/// model- or prompt-controlled.
public struct NewScheduledJob: Sendable, Equatable {
  public let ownerChatId: Int64
  public let label: String
  public let prompt: String
  public let recurrence: RecurrenceEnvelope?
  public let timezone: String
  public let nextOccurrence: Date

  public init(
    ownerChatId: Int64,
    label: String,
    prompt: String,
    recurrence: RecurrenceEnvelope?,
    timezone: String,
    nextOccurrence: Date
  ) {
    self.ownerChatId = ownerChatId
    self.label = label
    self.prompt = prompt
    self.recurrence = recurrence
    self.timezone = timezone
    self.nextOccurrence = nextOccurrence
  }
}

/// The single `scheduler_state` row — doctor is a separate process, so only
/// persisted state is visible to it.
public struct SchedulerState: Sendable, Equatable {
  public let lastTickAt: Date?
  public let lastMisfireAt: Date?
  public let lastMisfireSkippedCount: Int
  public let lastHeartbeatAt: Date?
  public let heartbeatCountDay: String?  // "YYYY-MM-DD" in CLAW_TIMEZONE
  public let heartbeatCount: Int

  public init(
    lastTickAt: Date?,
    lastMisfireAt: Date?,
    lastMisfireSkippedCount: Int,
    lastHeartbeatAt: Date?,
    heartbeatCountDay: String?,
    heartbeatCount: Int
  ) {
    self.lastTickAt = lastTickAt
    self.lastMisfireAt = lastMisfireAt
    self.lastMisfireSkippedCount = lastMisfireSkippedCount
    self.lastHeartbeatAt = lastHeartbeatAt
    self.heartbeatCountDay = heartbeatCountDay
    self.heartbeatCount = heartbeatCount
  }
}
