import ClawCore
import Foundation
import GRDB

/// One run's persisted transcript, reduced to what evidence may carry. The message rows are the
/// only lifecycle log there is, so "what the run did" is derived here and nowhere else.
struct RunTranscript {
  let finalOutput: String
  let facts: [EvidenceToolFact]
  let proposedCalls: Int
  let observedCalls: Int

  var summary: EvidenceTranscript {
    EvidenceTranscript(
      proposedCalls: proposedCalls,
      observedCalls: observedCalls,
      finalOutputBytes: finalOutput.utf8.count
    )
  }
}

// MARK: - Transcript Derivation

extension ScheduledLearningStoreGRDB {
  static func readTranscript(_ db: Database, runId: Int64) throws -> RunTranscript {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT role, content, tool_calls, tool_call_id FROM messages
        WHERE run_id = ? ORDER BY id
        """,
      arguments: [runId]
    )

    var proposed: [ToolCall] = []
    var observedCallIds: Set<String> = []
    var observedCalls = 0
    var finalOutput = ""

    for row in rows {
      let role = MessageRole(rawValue: row["role"])
      let toolCallsJSON: String? = row["tool_calls"]
      switch (role, toolCallsJSON) {
      case (.assistant, .some(let json)):
        proposed.append(contentsOf: ToolCallCoding.decode(json))
      case (.assistant, .none):
        // The last plain assistant row is the answer the owner received; an earlier one belongs to
        // a superseded step of the same run.
        finalOutput = row["content"]
      case (.tool, _):
        observedCalls += 1
        if let callId: String = row["tool_call_id"] {
          observedCallIds.insert(callId)
        }
      default:
        continue
      }
    }

    return RunTranscript(
      finalOutput: finalOutput,
      facts: proposed.prefix(EvidenceLimits.maxToolFacts).enumerated().map { ordinal, call in
        EvidenceToolFact(
          ordinal: ordinal,
          name: call.name,
          observed: observedCallIds.contains(call.id)
        )
      },
      proposedCalls: proposed.count,
      observedCalls: observedCalls
    )
  }
}

// MARK: - Payload Assembly

extension ScheduledLearningStoreGRDB {
  /// Every version in the payload is copied off the frozen `run_compatibility` row rather than
  /// recomputed: the workspace, the tool catalog and the route may all have moved since pickup, and
  /// a payload stamped with today's surface would file the run in the wrong evidence window.
  static func buildPayload(
    _ db: Database,
    runId: Int64,
    binding: RunLearningBinding,
    compatibility: RunCompatibility,
    transcript: RunTranscript
  ) throws -> EvidencePayload {
    let source = try readSource(db, runId: runId)
    return EvidencePayload(
      schemaVersion: EvidenceLimits.schemaVersion,
      jobDefinitionDigest: binding.jobDefinitionDigest.rawValue,
      effectiveLessonSetDigest: binding.effectiveDigest.rawValue,
      sourceMessageId: source.messageId,
      sourceDigest: source.digest,
      finalOutput: transcript.finalOutput,
      toolFacts: transcript.facts,
      proposedCalls: transcript.proposedCalls,
      observedCalls: transcript.observedCalls,
      contextSchemaVersion: compatibility.contextSchemaVersion,
      toolCatalogDigest: compatibility.toolCatalogDigest,
      policyVersion: compatibility.policyVersion,
      skillSetDigest: compatibility.skillSetDigest,
      configuredRoute: compatibility.configuredRoute,
      terminalRoute: try readTerminalRoute(db, runId: runId),
      usageRowIds: try Int64.fetchAll(
        db,
        sql: "SELECT id FROM provider_usage WHERE run_id = ? ORDER BY id",
        arguments: [runId]
      )
    )
  }
}

// MARK: - Provenance Rows

private extension ScheduledLearningStoreGRDB {
  /// The trigger message identifies the task the run answered. Its content is digested rather than
  /// copied: the evidence row exists to judge the answer, and the prompt already reaches the
  /// evaluator through the job definition.
  static func readSource(_ db: Database, runId: Int64) throws -> (messageId: Int64, digest: String)
  {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT messages.id AS message_id, messages.content AS content
        FROM runs JOIN messages ON messages.id = runs.trigger_message_id
        WHERE runs.id = ?
        """,
      arguments: [runId]
    )
    guard let row else {
      return (messageId: 0, digest: "")
    }
    let content: String = row["content"]
    return (messageId: row["message_id"], digest: SHA256Digest.hex(content))
  }
}
