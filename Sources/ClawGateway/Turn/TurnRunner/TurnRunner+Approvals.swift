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
    usage: ProviderUsage,
    outcome: TurnOutcome,
    in context: CommitContext
  ) async throws {
    // Invariant: `.suspended` is only returned after `outcome.exchanges.append(...)` upstream, so
    // `exchanges.last` is never nil on this path — this branch is defensive-only, unreachable today.
    // `usage` here is the SAME intermediate usage AgentRuntime already recorded mid-loop; passing it
    // to `commitDegradation` would debit `provider_usage` a second time for the same round. Pass
    // `nil` so this dead fallback can never double-debit even if the invariant above ever broke.
    guard let anchor = outcome.exchanges.last else {
      logger.error("suspended turn for run \(context.runId) carried no exchange; failing in-band")
      try commitContextUnavailable(
        runId: context.runId,
        sessionId: context.sessionId,
        chatId: context.chatId,
        setTainted: outcome.ingestedUntrusted,
        at: context.committedAt
      )
      return
    }

    let nonce = ApprovalNonce.generate()
    let completed =
      anchor.observations
      .filter { $0.callId != pending.toolCallId }
      .map { ToolObservationRow(toolCallId: $0.callId, content: $0.content) }

    let commit = SuspendedTurnCommit(
      assistantContent: anchor.assistantContent,
      toolCallsJSON: ToolCallCoding.encode(anchor.toolCalls) ?? "[]",
      completedObservations: completed,
      pending: pending,
      ownerUserId: context.chatId,
      nonce: nonce,
      promptChunks: approvalPromptChunks(
        pending: pending,
        outcome: outcome,
        chatId: context.chatId,
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
        runId: context.runId,
        sessionId: context.sessionId,
        commit: commit,
        now: context.committedAt
      )
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      logger.debug("suspend commit did not apply for run \(context.runId): \(error)")
      return
    }

    notifyOutbox()
    // Holds THIS lane Task until the approval resolves; the waiter performs the resume/deny.
    await parker.park(
      approvalId: receipt.approvalId,
      runId: context.runId,
      sessionId: context.sessionId,
      chatId: context.chatId,
      revalidatePolicyOnApprove: false
    )
  }
}

// MARK: - Approval Prompt

private extension TurnRunner {
  /// The approval prompt as outbox chunks — split at the Telegram message limit with the inline
  /// keyboard on the final chunk; the store stamps `approval_id` onto that keyboard-carrying row.
  func approvalPromptChunks(
    pending: PendingToolAction,
    outcome: TurnOutcome,
    chatId: Int64,
    nonce: String
  ) -> [OutboxChunk] {
    ToolApprovalPrompt.chunks(
      for: ToolApprovalPrompt.Input(
        recorded: pending.recorded,
        taintBanner: outcome.ingestedUntrusted,
        privilegedFileBanner: Self.isPrivilegedFile(pending.recorded.canonicalTarget)
      ),
      chatId: chatId,
      nonce: nonce
    )
  }

  /// Privileged-file banner: every owner-editable file that steers a later turn. Basename match on
  /// the resolved canonical target.
  static func isPrivilegedFile(_ canonicalTarget: String) -> Bool {
    WorkspaceFile.isPromptPrivileged(basename: (canonicalTarget as NSString).lastPathComponent)
  }
}
