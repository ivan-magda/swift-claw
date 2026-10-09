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

  @Test
  func fetchPreviewIdentifiesThePageWithoutPrivateURLComponents() async {
    // given
    let tool = ProgressTestTool(name: "web_fetch")
    let state = DispatchProgressState()
    state.releaseIdentification.open()
    let dispatcher = progressDispatcher(tool: tool)

    // when
    _ = await dispatcher.dispatch(
      call: ToolCall(
        id: "step",
        name: tool.definition.name,
        argumentsJSON:
          #"{"url":"https://user:password@swift.org/getting-started/?token=hidden#part"}"#
      ),
      context: progressDispatchContext(),
      progress: state.reporter
    )

    // then
    #expect(await state.latest.steps.first?.preview == "swift.org/getting-started/")
  }

  @Test
  func workspaceRelativeFilePathIsSuppliedAsThePreview() async {
    // when
    let previews = await previewsSupplied(forFileReadPath: "folder/file.txt")

    // then
    #expect(previews == ["folder/file.txt"])
  }

  @Test
  func filePathOutsideTheWorkspaceIsNotSupplied() async {
    // when
    let previews = await previewsSupplied(forFileReadPath: "../private.txt")

    // then — the reducer filters again, so this checks what dispatch itself supplied.
    #expect(previews == [nil])
  }

  @Test(arguments: [false, true])
  func longFetchPreviewKeepsTheLeafAfterRedaction(longLeaf: Bool) async throws {
    // given
    let secret = String(repeating: "s", count: 140)
    let ancestors = String(repeating: "guides/", count: 25)
    let pathSecret = longLeaf ? String(repeating: "%73", count: 140) : secret
    let leaf = (longLeaf ? String(repeating: "v", count: 150) : "") + "installation-" + pathSecret
    let tool = ProgressTestTool(name: "web_fetch")
    let state = DispatchProgressState()
    state.releaseIdentification.open()
    let dispatcher = progressDispatcher(tool: tool, secrets: [secret])

    // when
    _ = await dispatcher.dispatch(
      call: ToolCall(
        id: "step",
        name: tool.definition.name,
        argumentsJSON: "{\"url\":\"https://swift.org/\(ancestors)\(leaf)\"}"
      ),
      context: progressDispatchContext(),
      progress: state.reporter
    )

    // then
    let preview = try #require(await state.latest.steps.first?.preview)
    #expect(preview.hasPrefix("swift.org/…/"))
    #expect(preview.hasSuffix("installation-" + SecretRedactor.replacement))
    #expect(preview.count <= TurnProgressLimits.previewCharacters)
    #expect(preview.contains(String(secret.prefix(20))) == false)
  }
}

// MARK: - File Previews

private extension ToolDispatchProgressTests {
  /// Dispatches one `file_read` call and returns every preview the dispatcher handed to progress.
  func previewsSupplied(forFileReadPath path: String) async -> [String?] {
    let tool = ProgressTestTool(name: BuiltinToolNames.fileRead)
    let state = DispatchProgressState()
    state.releaseIdentification.open()

    _ = await progressDispatcher(tool: tool).dispatch(
      call: ToolCall(
        id: "step",
        name: tool.definition.name,
        argumentsJSON: "{\"path\":\"\(path)\"}"
      ),
      context: progressDispatchContext(),
      progress: state.reporter
    )

    return await state.suppliedPreviews
  }
}

private enum DispatchScenario {
  case allowed, denied, malformed, approval
}

actor DispatchProgressState {
  nonisolated let identified = AsyncGate()
  nonisolated let releaseIdentification = AsyncGate()
  private(set) var history: [ToolProgressState] = []
  private(set) var suppliedPreviews: [String?] = []
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
    suppliedPreviews.append(preview)
    state.apply(.toolStarted(id: id, tool: tool, preview: preview))
  }

  func publish(_ value: ToolProgressState) {
    state.apply(.toolState(id: id, state: value))
    if let observed = latest.steps.first?.state {
      history.append(observed)
    }
  }
}
