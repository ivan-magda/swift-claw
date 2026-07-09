import ClawCore
import Foundation
import Logging

/// Executes an APPROVED action from its recorded canonical args and commits the observation/run
/// transition (§6.3/§6.6). No gate re-trip, no model turn — grant semantics are gone; this is
/// recorded-args execution. Tools are held by name as ClawCore `Tool`s: the executor never imports
/// `ClawTools`; the composition root injects the same instances the dispatcher uses.
public protocol ApprovedActionExecuting: Sendable {
  func executeApproved(_ approval: Approval) async -> ApprovedExecutionOutcome
}

public struct ApprovedExecutionOutcome: Sendable, Equatable {
  /// What the placeholder observation now says (the waiter forwards nothing — the executor already
  /// committed it; this is returned for logging/assertions).
  public let observationContent: String
  /// `.committed` when this call performed the resume; `.ignored` when a duplicate already did.
  public let commit: RunCommitResult

  public init(observationContent: String, commit: RunCommitResult) {
    self.observationContent = observationContent
    self.commit = commit
  }
}

public struct ApprovedActionExecutor: ApprovedActionExecuting {
  /// `memory_write`'s side effect is a DB insert that must FUSE with the observation update for
  /// exactly-once (D10), so it never runs the tool's `execute`; every other write tool executes
  /// its recorded args, then commits the observation generically.
  private static let memoryWriteToolName = "memory_write"

  private let tools: [String: any Tool]
  private let runs: any RunStore
  private let now: @Sendable () -> Date
  private let logger: Logger

  public init(
    tools: [String: any Tool],
    runs: any RunStore,
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.tools = tools
    self.runs = runs
    self.now = now
    self.logger = logger
  }

  public func executeApproved(_ approval: Approval) async -> ApprovedExecutionOutcome {
    if approval.tool == Self.memoryWriteToolName {
      return applyMemoryWrite(approval)
    }
    return await executeGenericWrite(approval)
  }
}

// MARK: - Generic Write Execution

private extension ApprovedActionExecutor {
  func executeGenericWrite(_ approval: Approval) async -> ApprovedExecutionOutcome {
    guard
      let tool = tools[approval.tool],
      let arguments = JSONValue.parse(approval.canonicalArgsJSON)
    else {
      logger.error("approved action \(approval.tool) has no registered tool or unparsable args")
      let content = "That action could not run because its tool is no longer available."
      return ApprovedExecutionOutcome(
        observationContent: content,
        commit: commitObservation(approval, content: content)
      )
    }

    // §6.6: run to completion on the waiter task — direct await, NEVER `executeWithTimeout`'s
    // abandon-on-timeout race, so the observation is always truthful (file_write is atomic).
    let payload = await tool.execute(
      arguments: arguments,
      canonicalTarget: approval.canonicalTarget
    )
    return ApprovedExecutionOutcome(
      observationContent: payload.content,
      commit: commitObservation(approval, content: payload.content)
    )
  }

  func commitObservation(_ approval: Approval, content: String) -> RunCommitResult {
    do {
      return try runs.completeApprovedObservation(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        content: content,
        now: now()
      )
    } catch {
      logger.error("completeApprovedObservation failed for run \(approval.runId): \(error)")
      return .ignored
    }
  }
}

// MARK: - Memory Write (Fused, Exactly-Once)

private extension ApprovedActionExecutor {
  func applyMemoryWrite(_ approval: Approval) -> ApprovedExecutionOutcome {
    guard let item = Self.rebuildMemoryItem(from: approval) else {
      logger.error("memory_write approval \(approval.id) has unreadable recorded args")
      let content = "That memory could not be saved because its details were unreadable."
      return ApprovedExecutionOutcome(
        observationContent: content,
        commit: commitObservation(approval, content: content)
      )
    }

    let content = "Saved to memory as \(item.kind.rawValue)."
    do {
      let commit = try runs.applyApprovedMemoryWrite(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        item: item,
        observationContent: content,
        now: now()
      )
      return ApprovedExecutionOutcome(observationContent: content, commit: commit)
    } catch {
      logger.error("applyApprovedMemoryWrite failed for run \(approval.runId): \(error)")
      return ApprovedExecutionOutcome(observationContent: content, commit: .ignored)
    }
  }

  /// Rebuilds the `NewMemoryItem` from the recorded canonical args. The args were already
  /// normalized + scanned at gate time (Task 22), so no re-normalization here.
  static func rebuildMemoryItem(from approval: Approval) -> NewMemoryItem? {
    guard
      let object = JSONValue.parse(approval.canonicalArgsJSON)?.objectValue,
      let text = object["text"]?.stringValue,
      let kindRaw = object["kind"]?.stringValue,
      let kind = MemoryKind(rawValue: kindRaw)
    else {
      return nil
    }
    let importance =
      object["importance"]?.numberValue.flatMap { Importance(rawValue: Int($0)) } ?? .normal
    let sensitivity =
      object["sensitivity"]?.stringValue.flatMap(Sensitivity.init(rawValue:)) ?? .normal
    // Task 22 flips `source` to `.assistant` (the case does not exist yet in Phase 3) and unifies
    // this decode with the shared `MemoryWriteArguments` decoder (Task 22 owns that unification).
    return NewMemoryItem(
      text: text,
      kind: kind,
      sensitivity: sensitivity,
      importance: importance,
      source: .owner,
      sessionId: approval.sessionId
    )
  }
}
