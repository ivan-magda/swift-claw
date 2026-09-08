import ClawCore
import Foundation
import Logging

// MARK: - Turn Diagnostics

extension AgentRuntime {
  /// The correlation fields stamped on every developer log line for one turn, so a single
  /// `grep run=<id>` ties the turn's round-trips, tool calls, and outcome together.
  /// Only a group turn stamps the conversation's shape, so a DM's log lines stay exactly as they
  /// were and a group turn is greppable by topic.
  static func turnMetadata(
    runId: Int64,
    sessionId: Int64,
    mode: ChatMode = .direct,
    threadId: Int64? = nil
  ) -> Logger.Metadata {
    var metadata: Logger.Metadata = ["run": "\(runId)", "session": "\(sessionId)"]
    guard mode == .group else {
      return metadata
    }
    metadata["mode"] = "\(mode.rawValue)"
    metadata["topic"] = "\(threadId.map(String.init) ?? "general")"
    return metadata
  }

  /// Emits the one finished line for a turn; its level reflects severity — completed → info,
  /// budget-stopped → notice (an expected guard), degraded → warning (something went wrong). Only
  /// safe fields (counts, tokens, cost, elapsed) are logged, never the reply text.
  static func logFinish(_ result: TurnResult, on log: Logger, elapsed: Duration) {
    let elapsedMillis = millis(elapsed)
    switch result {
    case .completed(let content, let usage, _):
      log.info(
        "turn finished completed chars=\(content.count) tokens=\(usage.promptTokens + usage.completionTokens) usd=\(USD.precise(usage.costUSD)) ms=\(elapsedMillis)"
      )
    case .degraded(let kind, let usage):
      let tokens = usage.map { "\($0.promptTokens + $0.completionTokens)" } ?? "n/a"
      log.warning(
        "turn finished degraded kind=\(kind.auditDecision) tokens=\(tokens) ms=\(elapsedMillis)"
      )
    case .budgetStopped(let cap):
      log.notice("turn finished budget-stopped cap=\(cap) ms=\(elapsedMillis)")
    case .suspended(let pending, let usage):
      log.info(
        "turn finished suspended tool=\(pending.recorded.tool) tokens=\(usage.promptTokens + usage.completionTokens) ms=\(elapsedMillis)"
      )
    }
  }

  /// Whole milliseconds of a `Duration`, for compact latency fields in developer logs.
  static func millis(_ duration: Duration) -> Int64 {
    let parts = duration.components
    return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
  }
}

// MARK: - Round-Trip Recording

extension AgentRuntime {
  /// One audit row per dispatch, written immediately, blocked calls included.
  func recordToolAudit(
    for call: ToolCall,
    outcome dispatched: ToolDispatchOutcome,
    runId: Int64,
    sessionId: Int64
  ) throws {
    try recordAudit(
      AuditEvent(
        actor: .assistant,
        action: .toolCall,
        tool: call.name,
        argsRedacted: dispatched.argsRedacted,
        resultSize: dispatched.observation.content.utf8.count,
        decision: dispatched.observation.status.rawValue,
        runId: runId,
        sessionId: sessionId,
        ts: Date()
      ),
      runId: runId,
      sessionId: sessionId
    )
  }

  /// Writes one audit row on the turn's single throwing contract. Audit is observability, not a
  /// gate: only a full disk stops the turn, any other write failure logs and the run continues.
  func recordAudit(_ event: AuditEvent, runId: Int64, sessionId: Int64) throws {
    do {
      try auditLog.appendAudit(event)
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      logger.warning(
        "audit write failed (continuing): \(error)",
        metadata: Self.turnMetadata(runId: runId, sessionId: sessionId)
      )
    }
  }
}
