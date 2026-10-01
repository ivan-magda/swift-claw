import ClawCore
import ClawGateway
import ClawTestSupport
import ClawTools
import Testing

@Suite
struct ToolDispatchProgressTests {
  @Test
  func executionStartsOnlyAfterAnAllowedGate() async {
    // given
    for scenario in [DispatchScenario.allowed, .denied, .malformed, .approval] {
      let started = AsyncGate()
      let release = AsyncGate()
      defer { release.open() }
      let tool = ProgressTestTool(
        risk: scenario == .approval ? .ask : .safe,
        started: started,
        release: release,
        status: .error
      )
      let state = DispatchProgressState()
      let dispatcher = progressDispatcher(tool: tool, secrets: ["private-secret"])
      let call = ToolCall(
        id: "step",
        name: tool.definition.name,
        argumentsJSON: scenario == .malformed
          ? "{" : "{\"query\":\"\(scenario == .denied ? "private-secret" : "weather")\"}"
      )

      // when
      let task = Task {
        await dispatcher.dispatch(
          call: call,
          context: progressDispatchContext(),
          progress: state.reporter
        )
      }
      #expect(await state.identified.waitUntilOpen())
      #expect(await state.latest.steps.first?.state == .pending)
      #expect(started.isOpen == false)
      state.releaseIdentification.open()
      if scenario == .allowed {
        #expect(await started.waitUntilOpen())
        #expect(await state.latest.steps.first?.state == .executing)
      }
      release.open()
      let outcome = await task.value

      // then
      let expected: ToolProgressState =
        switch scenario {
        case .allowed, .malformed:
          .failed
        case .denied:
          .denied
        case .approval:
          .awaitingApproval
        }
      #expect(await state.latest.steps.first?.state == expected)
      #expect(outcome.observation.status != .ok)
      #expect(started.isOpen == (scenario == .allowed))
      if scenario != .allowed {
        let history = await state.history
        #expect(history.contains(.executing) == false)
        #expect(history.contains(.succeeded) == false)
      }
    }
  }

  @Test
  func selectedPreviewIsRedactedBeforeItsCap() async {
    // given
    let secret = String(repeating: "s", count: 140)
    let tool = ProgressTestTool()
    let state = DispatchProgressState()
    state.releaseIdentification.open()
    let dispatcher = progressDispatcher(tool: tool, secrets: [secret])

    // when
    _ = await dispatcher.dispatch(
      call: ToolCall(
        id: "step",
        name: tool.definition.name,
        argumentsJSON: "{\"query\":\"prefix \(secret)\"}"
      ),
      context: progressDispatchContext(),
      progress: state.reporter
    )

    // then — this reducer has no secrets, so it cannot repair an upstream truncated credential.
    let preview = await state.latest.steps.first?.preview
    #expect(preview == "prefix " + SecretRedactor.replacement)
  }
}

private enum DispatchScenario {
  case allowed, denied, malformed, approval
}

actor DispatchProgressState {
  nonisolated let identified = AsyncGate()
  nonisolated let releaseIdentification = AsyncGate()
  private(set) var history: [ToolProgressState] = []
  private var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: [])
  private let id = TurnToolStepID(providerCallID: "round", toolCallID: "step")

  var latest: TurnProgressSnapshot {
    state.snapshot(elapsedSeconds: 0)
  }

  nonisolated var reporter: ToolProgressReporter {
    ToolProgressReporter { tool, preview in
      await self.identify(tool: tool, preview: preview)
      self.identified.open()
      await self.releaseIdentification.wait()
    } publish: { state in
      await self.publish(state)
    }
  }

}

// MARK: - Dispatch State Updates

private extension DispatchProgressState {
  func identify(tool: ToolDefinition?, preview: String?) {
    state.apply(.toolStarted(id: id, tool: tool, preview: preview))
  }

  func publish(_ value: ToolProgressState) {
    state.apply(.toolState(id: id, state: value))
    if let observed = latest.steps.first?.state {
      history.append(observed)
      if history.count > 32 {
        history.removeFirst()
      }
    }
  }
}
