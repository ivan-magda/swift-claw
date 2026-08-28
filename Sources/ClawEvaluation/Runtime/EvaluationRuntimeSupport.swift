import ClawCore
import ClawTools
import Foundation
import Synchronization

struct EvaluationToolRecord: Codable, Sendable, Equatable {
  package let name: String
  package let path: String?
  package let status: String

  package init(name: String, path: String?, status: String) {
    self.name = name
    self.path = path
    self.status = status
  }
}

actor EvaluationToolRecorder {
  private var stored: [EvaluationToolRecord] = []
  private let progressRecorder: EvaluationAttemptProgressRecorder?
  private let attemptID: String?

  package init(
    progressRecorder: EvaluationAttemptProgressRecorder? = nil,
    attemptID: String? = nil
  ) {
    self.progressRecorder = progressRecorder
    self.attemptID = attemptID
  }

  package func recordFileReadStart() throws {
    if let progressRecorder, let attemptID {
      try progressRecorder.recordFileRead(attemptID: attemptID)
    }
  }

  package func append(_ record: EvaluationToolRecord) {
    stored.append(record)
  }

  package func records() -> [EvaluationToolRecord] {
    stored
  }
}

struct EvaluationToolDispatcher: ToolDispatching {
  package let definitions: [ToolDefinition]
  private let wrapped: GatedToolDispatcher
  private let allowedFileName: String
  private let recorder: EvaluationToolRecorder

  package init(
    workspaceRoot: URL,
    allowedFileName: String,
    recorder: EvaluationToolRecorder
  ) {
    let fileRead = FileReadTool(
      workspaceRoot: workspaceRoot,
      redactor: SecretRedactor(secretValues: [])
    )
    let registry = ToolRegistry(tools: [fileRead])
    self.definitions = registry.definitions
    self.wrapped = GatedToolDispatcher(
      registry: registry,
      gate: ToolPolicyGate(
        argGuard: ExfilArgGuard(secretValues: []),
        privateFileLoader: { [] },
        execEnabled: false
      )
    )
    self.allowedFileName = allowedFileName
    self.recorder = recorder
  }

  package func dispatch(
    call: ToolCall,
    context: ToolDispatchContext
  ) async -> ToolDispatchOutcome {
    let path = JSONValue.parse(call.argumentsJSON)?.objectValue?["path"]?.stringValue
    if call.name == EvaluationToolContract.requiredToolName, path != allowedFileName {
      let outcome = ToolDispatchOutcome(
        observation: ToolObservation(
          callId: call.id,
          toolName: call.name,
          content: "The evaluation file path is not allowlisted.",
          status: .error,
          ingestedUntrusted: false
        ),
        argsRedacted: #"{"path":"<rejected>"}"#
      )
      await recorder.append(
        EvaluationToolRecord(
          name: call.name,
          path: path,
          status: EvaluationToolContract.failedStatus
        )
      )
      return outcome
    }
    if call.name == EvaluationToolContract.requiredToolName {
      do {
        try await recorder.recordFileReadStart()
      } catch {
        let outcome = ToolDispatchOutcome(
          observation: ToolObservation(
            callId: call.id,
            toolName: call.name,
            content: "The evaluation read could not be durably accounted.",
            status: .error,
            ingestedUntrusted: false
          ),
          argsRedacted: #"{"path":"<unavailable>"}"#
        )
        await recorder.append(
          EvaluationToolRecord(
            name: call.name,
            path: path,
            status: EvaluationToolContract.failedStatus
          )
        )
        return outcome
      }
    }
    let outcome = await wrapped.dispatch(call: call, context: context)
    await recorder.append(
      EvaluationToolRecord(
        name: call.name,
        path: path,
        status: outcome.observation.status == .ok
          ? EvaluationToolContract.succeededStatus : EvaluationToolContract.failedStatus
      )
    )
    return outcome
  }
}

final class EvaluationUsageStore: UsageStore, @unchecked Sendable {
  private let storage = Mutex<[ProviderUsage]>([])
  private let progressRecorder: EvaluationAttemptProgressRecorder?
  private let attemptID: String?

  package init(
    progressRecorder: EvaluationAttemptProgressRecorder? = nil,
    attemptID: String? = nil
  ) {
    self.progressRecorder = progressRecorder
    self.attemptID = attemptID
  }

  package var rows: [ProviderUsage] {
    storage.withLock { rows in
      rows
    }
  }

  package func recordUsage(_ usage: ProviderUsage) throws(StoreError) {
    if let progressRecorder, let attemptID {
      do {
        try progressRecorder.recordUsage(attemptID: attemptID, usage: usage)
      } catch {
        throw .unexpected("evaluation progress publication failed")
      }
    }
    storage.withLock { rows in
      rows.append(usage)
    }
  }

  package func todayTokensAndCost(now: Date) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    (0, 0)
  }

  package func todayTokensAndCost(
    origins: [RunOrigin],
    now: Date
  ) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    (0, 0)
  }

  package func costSourceMix(now: Date) throws(StoreError) -> [CostSource: Int] {
    [:]
  }

  package func latestPromptUsage() throws(StoreError) -> LatestPromptUsage? {
    storage.withLock { rows in
      rows.last.map { usage in
        LatestPromptUsage(
          promptTokens: usage.promptTokens,
          runId: usage.runId,
          isEstimated: usage.isEstimated
        )
      }
    }
  }
}

struct EvaluationAuditRecord: Codable, Sendable, Equatable {
  let actor: String
  let action: String
  let tool: String?
  let argsRedacted: String
  let resultSize: Int
  let decision: String
  let runID: Int64?
  let sessionID: Int64?
  let timestamp: String

  init(_ event: AuditEvent) {
    actor = event.actor.rawValue
    action = event.action.rawValue
    tool = event.tool
    argsRedacted = event.argsRedacted
    resultSize = event.resultSize
    decision = event.decision
    runID = event.runId
    sessionID = event.sessionId
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    timestamp = formatter.string(from: event.ts)
  }

  enum CodingKeys: String, CodingKey {
    case actor, action, tool, decision, timestamp
    case argsRedacted = "args_redacted"
    case resultSize = "result_size"
    case runID = "run_id"
    case sessionID = "session_id"
  }
}

/// Captures the runtime's safe audit events so the immutable attempt result persists them beside
/// usage, tool, and provider observations.
final class EvaluationAuditLog: AuditLog, @unchecked Sendable {
  private let storage = Mutex<[EvaluationAuditRecord]>([])

  var records: [EvaluationAuditRecord] {
    storage.withLock { records in records }
  }

  func appendAudit(_ event: AuditEvent) throws(StoreError) {
    storage.withLock { records in
      records.append(EvaluationAuditRecord(event))
    }
  }
}

enum EvaluationToolViolation: String, Codable, Sendable, Equatable {
  case expectedOneFileRead = "expected_one_file_read"
  case unexpectedTool = "unexpected_tool"
  case unexpectedFileReadPath = "unexpected_file_read_path"
  case fileReadFailed = "file_read_failed"
  case unexpectedSuspension = "unexpected_suspension"
}

enum EvaluationToolContract {
  package static let requiredToolName = "file_read"
  package static let succeededStatus = "succeeded"
  package static let failedStatus = "failed"

  package static func observedFileReads(
    in records: [EvaluationToolRecord],
    expectedPath: String
  ) -> Int {
    records.filter { record in
      record.name == requiredToolName && record.path == expectedPath
    }.count
  }

  package static func violation(
    in records: [EvaluationToolRecord],
    expectedPath: String = PageEvaluationContract.inputFileName
  ) -> EvaluationToolViolation? {
    guard records.count == 1 else {
      return .expectedOneFileRead
    }
    let record = records[0]
    guard record.name == requiredToolName else {
      return .unexpectedTool
    }
    guard record.path == expectedPath else {
      return .unexpectedFileReadPath
    }
    guard record.status == succeededStatus else {
      return .fileReadFailed
    }
    return nil
  }
}
