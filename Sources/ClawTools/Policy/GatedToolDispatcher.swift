import ClawCore
import Foundation

/// The full per-call order behind the loop's `ToolDispatching` seam: (0) lookup → (1) parse →
/// (2)/(3) gate → (4) execute under the tool's own timeout. Audit is the LOOP's job.
public struct GatedToolDispatcher: ToolDispatching {
  private let registry: ToolRegistry
  private let gate: ToolPolicyGate
  private let secretValues: [String]
  /// Injected so tests drive the timeout race deterministically (same seam as `AgentRuntime`).
  private let clock: any Clock<Duration>

  public init(
    registry: ToolRegistry,
    gate: ToolPolicyGate,
    clock: any Clock<Duration> = ContinuousClock(),
    secretValues: [String] = []
  ) {
    self.registry = registry
    self.gate = gate
    self.clock = clock
    self.secretValues = secretValues
  }

  public var definitions: [ToolDefinition] {
    registry.definitions
  }

  /// The same name-keyed catalog `dispatch` gates through, surfaced so the composition root
  /// can build `ApprovedActionExecutor` against the identical tool instances.
  public var toolsByName: [String: any Tool] {
    registry.toolsByName
  }

  public func dispatch(
    call: ToolCall,
    context: ToolDispatchContext
  ) async -> ToolDispatchOutcome {
    await dispatch(call: call, context: context, progress: nil)
  }

  public func dispatch(
    call: ToolCall,
    context: ToolDispatchContext,
    progress: ToolProgressReporter?
  ) async -> ToolDispatchOutcome {
    let tool = registry.tool(named: call.name)
    await progress?.identify(
      tool: tool?.definition,
      preview: tool.flatMap { registeredTool in
        preview(call: call, name: registeredTool.definition.name)
      }
    )
    await progress?.publish(.pending)
    // (0) unknown tool → error observation, never a crash
    guard let tool else {
      await progress?.publish(.failed)
      return errorOutcome(call: call, reason: "Unknown tool \(call.name).")
    }
    // (1) malformed argumentsJSON → error observation
    guard let arguments = JSONValue.parse(call.argumentsJSON) else {
      await progress?.publish(.failed)
      return errorOutcome(call: call, reason: "Malformed arguments for \(call.name).")
    }
    // (2)/(3) the gate
    switch await gate.evaluate(call: call, tool: tool, context: context) {
    case .block(let payload, let argsRedacted):
      await progress?.publish(.denied)
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted
      )
    case .requireApproval(let recorded):
      await progress?.publish(.awaitingApproval)
      // The recorded action rides the outcome to the loop, which sets the pending action
      // and returns `.suspended`. The observation is the placeholder the suspend commit
      // persists in place and updates at resolution — the pending call itself does not execute now.
      return ToolDispatchOutcome(
        observation: ToolObservation(
          callID: call.id,
          toolName: call.name,
          content: "awaiting owner approval",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: gate.renderRedacted(argsJSON: recorded.canonicalArgsJSON),
        requiresApproval: recorded
      )
    case .allow(let argsRedacted, let action, let preparedArgsJSON):
      await progress?.publish(.executing)
      // (4) execute under the tool's own timeout, on the gate-resolved canonical target
      let payload = await executeWithTimeout(
        tool: tool,
        arguments: arguments,
        preparedArgsJSON: preparedArgsJSON,
        canonicalTarget: action?.target,
        context: context.executionContext
      )
      await progress?.publish(
        Task.isCancelled ? .cancelled : ToolProgressState(observationStatus: payload.status)
      )
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted
      )
    }
  }
}

// MARK: - Execution

private extension GatedToolDispatcher {
  /// Caller cancellation cancels execution and joins cleanup within the original deadline.
  /// Deadline expiry abandons a tool that ignores cancellation so it cannot hold the lane forever.
  ///
  /// A group turn dispatches write tools here, so the abandonment is no longer free — and it is
  /// still the right trade. `file_write` commits through a staged temp file and a single
  /// `rename(2)`/`link(2)`, so an abandoned write either lands whole or leaves the previous file
  /// untouched; there is no torn state to observe. `execute_code` runs inside a sandbox that
  /// enforces its own shorter timeout, and the dispatcher's allowance sits 20s above it, so the
  /// race fires only when the sandbox itself has already wedged — exactly the case worth
  /// abandoning. In both cases the turn observes a timeout, which may understate what happened;
  /// the alternative is a wedged tool holding the session lane, which is worse.
  func executeWithTimeout(
    tool: any Tool,
    arguments: JSONValue,
    preparedArgsJSON: String?,
    canonicalTarget: String?,
    context: ToolExecutionContext?
  ) async -> ToolPayload {
    let executedArguments: JSONValue
    if let preparedArgsJSON {
      guard let prepared = JSONValue.parse(preparedArgsJSON) else {
        return ToolPayload(
          content: "The prepared \(tool.definition.name) action is unreadable; nothing ran.",
          status: .error,
          ingestedUntrusted: false
        )
      }
      executedArguments = prepared
    } else {
      executedArguments = arguments
    }

    let execution = Task {
      await tool.execute(
        arguments: executedArguments,
        canonicalTarget: canonicalTarget,
        context: context
      )
    }
    // This owned task does not inherit caller cancellation: the original deadline must keep
    // running while execution responds to cancellation and finishes its cleanup.
    let deadline = Task {
      await DeadlineRace.race(
        allowance: tool.timeout,
        sleep: { [clock] duration in
          try await clock.sleep(for: duration)
        },
        operation: {
          await execution.value
        }
      )
    }

    let outcome = await withTaskCancellationHandler {
      await deadline.value
    } onCancel: {
      execution.cancel()
    }
    execution.cancel()

    switch outcome {
    case .operationReturned(let payload) where !Task.isCancelled:
      return payload
    case .operationReturned, .deadlineExpired, .callerCancelled:
      return ToolPayload(
        content: "The \(tool.definition.name) call timed out.",
        status: .error,
        ingestedUntrusted: false
      )
    }
  }

  func errorOutcome(call: ToolCall, reason: String) -> ToolDispatchOutcome {
    ToolDispatchOutcome(
      observation: ToolObservation(
        callID: call.id,
        toolName: call.name,
        content: reason,
        status: .error,
        ingestedUntrusted: false
      ),
      argsRedacted: gate.renderRedacted(argsJSON: call.argumentsJSON)
    )
  }
}

// MARK: - Display Inputs

private extension GatedToolDispatcher {
  func preview(call: ToolCall, name: String) -> String? {
    guard let arguments = JSONValue.parse(call.argumentsJSON)?.objectValue else {
      return nil
    }

    let selected: String?
    switch name {
    case BuiltinToolNames.webSearch:
      selected = arguments["query"]?.stringValue
    case BuiltinToolNames.skillLoad:
      selected = arguments["name"]?.stringValue
    case BuiltinToolNames.webFetch:
      selected = arguments["url"]?.stringValue
        .flatMap(URLComponents.init(string:))
        .flatMap { components in
          ProgressText.webPagePreview(components, secretValues: secretValues)
        }
    case BuiltinToolNames.fileRead, BuiltinToolNames.fileWrite:
      selected = arguments["path"]?.stringValue.flatMap { path in
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.contains(":")
        else {
          return nil
        }

        let containsControlCharacters = path.unicodeScalars.contains { scalar in
          CharacterSet.controlCharacters.contains(scalar)
        }
        guard !containsControlCharacters else {
          return nil
        }

        let validPathComponents =
          path
          .split(separator: "/", omittingEmptySubsequences: false)
          .allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
          }
        guard validPathComponents else {
          return nil
        }

        return path
      }
    default:
      selected = nil
    }

    return selected.map {
      ProgressText.preview(
        $0,
        secretValues: secretValues,
        limit: TurnProgressLimits.previewCharacters
      )
    }
  }
}
