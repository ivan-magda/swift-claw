import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawTestSupport
import ClawTools

struct ProgressTestTool: Tool {
  var risk: RiskLevel = .safe
  var started: AsyncGate?
  var release: AsyncGate?
  var status: ToolObservationStatus = .ok

  var definition: ToolDefinition {
    ToolDefinition(
      name: "web_search",
      description: "Search",
      parameters: .object([:]),
      metadataProvenance: .trusted,
      egressClass: .fixedEndpoint,
      riskLevel: risk
    )
  }

  let timeout: Duration = .seconds(60)

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    .resolved("search")
  }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    started?.open()
    await release?.wait()
    return ToolPayload(content: "result", status: status, ingestedUntrusted: false)
  }
}

func progressDispatcher(tool: any Tool, secrets: [String] = []) -> GatedToolDispatcher {
  GatedToolDispatcher(
    registry: ToolRegistry(tools: [tool]),
    gate: ToolPolicyGate(
      argGuard: ExfilArgGuard(secretValues: secrets),
      privateFileLoader: { [] },
      enabledDangerousTools: []
    ),
    secretValues: secrets
  )
}

func progressDispatchContext() -> ToolDispatchContext {
  ToolDispatchContext(
    sessionTainted: false,
    runIngestedUntrusted: false,
    assemblyPrivateData: false,
    runPrivateData: false,
    sessionHasPrivateData: false,
    approvalAlreadyPending: false
  )
}

actor ProgressSequenceProvider: LLMProvider {
  let interimSeen: AsyncGate
  let explanation = "Checking the forecast"
  let interim = "I will check that"
  private(set) var requests: [ChatRequest] = []

  init(interimSeen: AsyncGate) {
    self.interimSeen = interimSeen
  }

  func complete(request: ChatRequest) -> ChatResponse {
    okResponse(content: "final answer")
  }

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { sink in
      await self.play(request: request, sink: sink)
    }
  }

}

// MARK: - Provider Script

private extension ProgressSequenceProvider {
  func play(request: ChatRequest, sink: LLMEventSink) async -> LLMStreamTermination {
    requests.append(request)
    do {
      if requests.count == 1 {
        try await sink.sendProgress(
          LLMProgressEvent(
            itemID: "summary",
            kind: .summary,
            text: .append(explanation)
          )
        )
        try await sink.sendDelta(interim)
        await interimSeen.wait()
        return .completed(
          toolCallResponse(
            [
              ToolCall(
                id: "same-call",
                name: "web_search",
                argumentsJSON: "{\"query\":\"weather\"}"
              ),
            ],
            content: interim
          )
        )
      }
      try await sink.sendDelta("final")
      return .completed(okResponse(content: "final answer"))
    } catch {
      return .cancelled(.mayHaveStarted(observing: 0))
    }
  }
}

actor MatchingProgressDrafts: RichDraftStreaming {
  nonisolated let interimSeen = AsyncGate()
  private(set) var markdowns: [String] = []

  func sendDraft(chatID: Int64, draftID: Int64, markdown: String) -> Bool {
    markdowns.append(markdown)
    if markdown.contains("I will check that") {
      interimSeen.open()
    }
    return true
  }
}

func makeProgressRuntime(
  provider: any LLMProvider,
  drafts: any RichDraftStreaming,
  streamingEnabled: Bool = true
) throws -> AgentRuntime {
  AgentRuntime(
    roster: makeSingleRouteRoster(provider: provider, wireModel: "test-model"),
    typingIndicator: NoopTyping(),
    draftStreamer: drafts,
    streamingEnabled: streamingEnabled,
    costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
    budget: .default,
    usageStore: UsageStoreGRDB(writer: try TestDatabase.make()),
    auditLog: RecordingAuditLog(),
    clock: ContinuousClock()
  )
}

func progressRequest(scope: TurnScope, reporter: TurnProgressReporter?) -> TurnRequest {
  TurnRequest(
    scope: scope,
    context: BuildResult(
      messages: [ChatMessage(role: .user, content: "hello")],
      ownerNotices: [],
      hasPrivateDataAccess: false
    ),
    session: SessionTrust(isTainted: false, hasPrivateData: false),
    spend: SpendSnapshot(todayTokens: 0, todayUSD: 0, proactiveTodayUSD: 0, carryOver: nil),
    progress: reporter
  )
}

actor ProgressSnapshots {
  private var state = TurnProgressState(showsProgress: true, resumed: false, secretValues: [])

  var latest: TurnProgressSnapshot {
    state.snapshot(elapsedSeconds: 0)
  }

  func publish(_ event: TurnProgressEvent) {
    state.apply(event)
  }
}
