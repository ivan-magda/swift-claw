import ClawAgent
import ClawCore
import Foundation

// MARK: - Suspend Commit

extension TurnRunner {
  /// Persists the suspend checkpoint, drains the prompt, then HOLDS the lane on the durable
  /// approval.
  /// A lost-arbitration race (a /stop//new already terminated the run) or a write fault rolls the
  /// commit back — there is nothing to park, so the turn simply ends (in-band, no throw escapes).
  func suspendForApproval(
    pending: PendingToolAction,
    outcome: TurnOutcome,
    in context: CommitContext
  ) async throws {
    // Invariant: the runtime returns `.suspended` only after appending the suspending round's
    // exchange, so `exchanges.last` is never nil on this path — this branch is defensive-only,
    // unreachable today.
    // AgentRuntime already recorded the intermediate usage mid-loop. The context-unavailable
    // fallback commits no usage, so it cannot debit the same round twice.
    guard let anchor = outcome.exchanges.last else {
      logger.error("suspended turn for run \(context.runID) carried no exchange; failing in-band")
      await presentations?.close(runID: context.runID)
      try commitContextUnavailable(
        runID: context.runID,
        sessionID: context.sessionID,
        chatID: context.chatID,
        setTainted: outcome.ingestedUntrusted,
        at: context.committedAt
      )
      return
    }

    let nonce = ApprovalNonce.generate()
    let completedObservations = anchor.observations
      .filter {
        $0.callID != pending.toolCallID
      }
      .map {
        ToolObservationRow(toolCallID: $0.callID, content: $0.content)
      }

    let commit = SuspendedTurnCommit(
      assistantContent: anchor.assistantContent,
      toolCallsJSON: ToolCallCoding.encode(anchor.toolCalls) ?? "[]",
      completedObservations: completedObservations,
      pending: pending,
      ownerUserID: context.chatID,
      nonce: nonce,
      promptChunks: approvalPromptChunks(
        pending: pending,
        outcome: outcome,
        chatID: context.chatID,
        mode: context.mode,
        nonce: nonce
      ),
      setTainted: outcome.ingestedUntrusted,
      setPrivateData: outcome.hadPrivateData,
      providerState: anchor.providerState,
      expiresTs: context.committedAt.addingTimeInterval(TimeInterval(approvalExpirySeconds))
    )

    let receipt: SuspendedCommitReceipt
    do {
      receipt = try runs.commitSuspendedTurn(
        runID: context.runID,
        sessionID: context.sessionID,
        commit: commit,
        now: context.committedAt
      )
    } catch StoreError.diskFull {
      await presentations?.close(runID: context.runID)
      throw StoreError.diskFull
    } catch {
      await presentations?.close(runID: context.runID)
      logger.debug("suspend commit did not apply for run \(context.runID): \(error)")
      return
    }

    await presentations?.waitingForApproval(runID: context.runID)
    notifyOutbox()
    // Holds THIS lane Task until the approval resolves; the waiter performs the resume/deny.
    await parker.park(
      approvalID: receipt.approvalID,
      runID: context.runID,
      sessionID: context.sessionID,
      chatID: context.chatID,
      revalidatePolicyOnApprove: false
    )
    await presentations?.close(runID: context.runID)
  }
}

// MARK: - Approval Prompt

private extension TurnRunner {
  /// The approval prompt as outbox chunks — split at the Telegram message limit with the inline
  /// keyboard on the final chunk; the store stamps `approval_id` onto that keyboard-carrying row.
  func approvalPromptChunks(
    pending: PendingToolAction,
    outcome: TurnOutcome,
    chatID: Int64,
    mode: ChatMode,
    nonce: String
  ) -> [OutboxChunk] {
    ToolApprovalPrompt.chunks(
      for: ToolApprovalPrompt.Input(
        recorded: pending.recorded,
        taintBanner: outcome.ingestedUntrusted,
        privilegedFileBanner: Self.isPrivilegedFile(pending.recorded),
        isGroup: mode == .group
      ),
      chatID: chatID,
      nonce: nonce
    )
  }

  /// Journal recognition was resolved against the workspace root by the write tool at gate time.
  static func isPrivilegedFile(_ recorded: RecordedToolAction) -> Bool {
    let basename = (recorded.canonicalTarget as NSString).lastPathComponent
    if WorkspaceFile.isPromptPrivileged(basename: basename) {
      return true
    }

    guard recorded.tool == BuiltinToolNames.fileWrite else {
      return false
    }

    return recorded.presentation.warnings.contains(WorkspaceFile.journalWriteWarning)
  }
}
