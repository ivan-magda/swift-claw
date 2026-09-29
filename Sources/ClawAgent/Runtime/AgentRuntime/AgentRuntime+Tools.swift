import ClawCore
import Logging

// MARK: - Tool Batch

extension AgentRuntime {
  /// Runs a round's proposed calls in order, each gated under the flags the calls before it left.
  /// The first action the gate parks suspends the turn after the batch; once the run is cancelled,
  /// no further call starts.
  func runToolBatch(
    _ round: AnsweredRound,
    ledger: inout RunSpendLedger,
    trust: inout TurnTrust
  ) async throws -> TurnStep<ToolBatch> {
    let turn = round.plan.turn
    await typingIndicator.sendTyping(
      chatID: turn.scope.chatID,
      messageThreadID: turn.scope.threadID
    )

    var batch = ToolBatch()
    for call in round.response.toolCalls {
      guard !Task.isCancelled else {
        break
      }

      guard ledger.admitToolCall() else {
        return .exit(.budgetStopped(cap: BudgetGate.perRunToolCallCap))
      }
      guard turn.deadline > now() else {
        return .exit(TurnExit(deadlineDegradation(round), failureCause: .deadline))
      }

      let context = trust.dispatchContext(
        for: call,
        scope: turn.scope,
        approvalAlreadyPending: batch.pending != nil
      )
      guard let toolDispatcher else {
        batch.observations.append(
          ToolObservation(
            callID: call.id,
            toolName: call.name,
            content: "No tools are available.",
            status: .error,
            ingestedUntrusted: false
          )
        )
        continue
      }

      let dispatched = await dispatch(call, context: context, to: toolDispatcher, log: turn.log)
      if batch.pending == nil, let recordedAction = dispatched.requiresApproval {
        batch.pending = PendingToolAction(toolCallID: call.id, recorded: recordedAction)
        continue
      }

      try recordToolAudit(
        for: call,
        outcome: dispatched,
        runID: turn.scope.runID,
        sessionID: turn.scope.sessionID
      )
      batch.observations.append(dispatched.observation)
      trust.absorb(dispatched.observation)
    }

    batch.interrupted = Task.isCancelled
    if batch.interrupted {
      batch.recordUnexecuted(round.response.toolCalls)
    }

    return .proceed(batch)
  }
}

// MARK: - Dispatch

private extension AgentRuntime {
  func dispatch(
    _ call: ToolCall,
    context: ToolDispatchContext,
    to dispatcher: any ToolDispatching,
    log: Logger
  ) async -> ToolDispatchOutcome {
    log.debug("tool \(call.name) invoked")

    let toolStart = now()
    let dispatched = await dispatcher.dispatch(call: call, context: context)

    log.debug(
      """
      tool \(call.name) done decision=\(dispatched.observation.status.rawValue) \
      bytes=\(dispatched.observation.content.utf8.count) \
      ms=\(Self.millis(now() - toolStart))
      """
    )

    return dispatched
  }
}
