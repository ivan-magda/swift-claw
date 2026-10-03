import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation

@testable import ClawGateway

actor LifecycleDrafts: RichDraftStreaming {
  struct Draft: Sendable {
    let draftID: Int64
    let markdown: String
  }

  nonisolated let firstSeen = AsyncGate()
  nonisolated let explanationSeen = AsyncGate()
  nonisolated let waitingSeen = AsyncGate()
  nonisolated let executingSeen = AsyncGate()
  nonisolated let resumedSeen = AsyncGate()
  nonisolated let completedStepSeen = AsyncGate()
  private(set) var drafts: [Draft] = []

  func sendDraft(chatID: Int64, draftID: Int64, markdown: String) -> Bool {
    drafts.append(Draft(draftID: draftID, markdown: markdown))
    firstSeen.open()
    if markdown.contains(ApprovalProgressProvider.explanation) {
      explanationSeen.open()
    }
    if markdown.contains("Waiting for your approval") {
      waitingSeen.open()
    }
    if markdown.contains("Executing") {
      executingSeen.open()
    }
    if markdown.contains("Succeeded") || markdown.contains("Failed") {
      completedStepSeen.open()
    }
    if markdown.contains("resumed answer") {
      resumedSeen.open()
    }
    return true
  }
}

actor ApprovalProgressProvider: LLMProvider {
  static let explanation = "Inspecting transient proposal details"
  let drafts: LifecycleDrafts
  let releaseFinal = AsyncGate()
  private var calls = 0

  init(drafts: LifecycleDrafts) {
    self.drafts = drafts
  }

  func complete(request: ChatRequest) -> ChatResponse {
    okResponse(content: "final answer")
  }

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { sink in
      await self.play(sink)
    }
  }

}

// MARK: - Approval Provider Script

private extension ApprovalProgressProvider {
  func play(_ sink: LLMEventSink) async -> LLMStreamTermination {
    calls += 1
    do {
      if calls == 1 {
        try await sink.sendProgress(
          LLMProgressEvent(
            itemID: "commentary",
            kind: .commentary,
            text: .replace(Self.explanation)
          )
        )
        await drafts.explanationSeen.wait()
        return .completed(
          toolCallResponse([
            ToolCall(id: "write", name: "progress_write", argumentsJSON: "{}"),
          ])
        )
      }
      await drafts.completedStepSeen.wait()
      try await sink.sendDelta("resumed answer")
      await releaseFinal.wait()
      return .completed(okResponse(content: "final answer"))
    } catch {
      return .cancelled(.mayHaveStarted(observing: 0))
    }
  }
}

struct ApprovedProgressTool: Tool {
  var status: ToolObservationStatus = .ok
  let started = AsyncGate()
  let release = AsyncGate()
  let timeout: Duration = .seconds(60)

  var definition: ToolDefinition {
    ToolDefinition(
      name: "progress_write",
      description: "Write",
      parameters: .object([:]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .ask
    )
  }

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    .resolved("write")
  }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    started.open()
    await release.wait()
    return ToolPayload(content: "saved", status: status, ingestedUntrusted: false)
  }
}

struct ProgressCompletionProvider: LLMProvider {
  let complete = AsyncGate()
  let started = AsyncGate()

  func complete(request: ChatRequest) async throws -> ChatResponse {
    started.open()
    await complete.wait()
    return okResponse(content: "answer")
  }
}

struct RegistrationTurn: TurnDispatching {
  let runs: any RunStore
  let presentations: TurnPresentationRegistry?
  let pickedUp: AsyncGate
  let admission: AsyncGate
  let attempted: AsyncGate
  let draftSeen: AsyncGate

  func run(runID: Int64, sessionID: Int64, chatID: Int64, triggerMessageID: Int64) async throws {
    guard try runs.pickUp(runID: runID, now: Date()) != nil else {
      return
    }
    pickedUp.open()
    await admission.waitIgnoringCancellation()
    let reporter = await presentations?.begin(
      scope: TurnScope(
        runID: runID,
        sessionID: sessionID,
        chatID: chatID,
        threadID: nil,
        mode: .direct,
        origin: .interactive,
        requesterUserID: chatID
      )
    )
    if reporter != nil {
      // A wrongly admitted sender must reach its unmanaged seam before the test drains it.
      let observation = Task { await draftSeen.waitUntilOpen() }
      _ = await observation.value
    }
    attempted.open()
  }
}

// MARK: - Stop Acknowledgement

func stoppedTransport(signal: AsyncGate) -> RecordingTransport {
  RecordingTransport(onSend: { text in
    if text == CommandReplies.stopped {
      signal.open()
    }
  })
}
