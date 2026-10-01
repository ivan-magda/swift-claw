import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent

/// What a landed draft asks the paced provider to do next.
private enum ContentStep: Sendable {
  /// Add content, then release the gate once the runtime has published it.
  case grow(TypingReleaseGate)
  case finish
}

/// Grows the reply only when a landed draft asks, and proves the runtime published the growth before
/// that draft returns: its one-delta buffer suspends each send until the consumer has drained the one
/// before, so the third of three sends returns only after the first was published. Every probe after
/// a draft therefore sees newer content, which leaves the draft cadence alone deciding when the next
/// draft goes out.
private struct DraftPacedProvider: LLMProvider {
  private static let oneDeltaBuffer = LLMEventBufferLimits(
    maximumDeltaCount: 1,
    maximumDeltaBytes: 8,
    reservedTerminalBytes: 1024
  )

  let steps: AsyncStream<ContentStep>

  func complete(request: ChatRequest) async throws -> ChatResponse {
    throw ProviderError.terminal(status: nil, message: "stream-only double")
  }

  func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make(limits: Self.oneDeltaBuffer) { sink in
      var content = ""
      do {
        try await sink.sendDelta("a")
        content += "a"
        for await step in steps {
          switch step {
          case .grow(let published):
            for piece in ["b", "c", "d"] {
              try await sink.sendDelta(piece)
              content += piece
            }
            await published.release()
          case .finish:
            return .completed(
              ChatResponse(
                content: content,
                finishReason: "stop",
                usage: nil,
                costFromProvider: nil
              )
            )
          }
        }
      } catch {
        return .cancelled(.mayHaveStarted(observing: 0))
      }
      return .cancelled(.mayHaveStarted(observing: 0))
    }
  }
}

/// Stamps each draft with the virtual time it went out, grows the reply after the first two drafts,
/// and ends the stream at the third.
private actor TickStampedDrafts: RichDraftStreaming {
  private let clock: ScriptedClock
  private let start: ScriptedClock.Instant
  private let steps: AsyncStream<ContentStep>.Continuation

  private(set) var sentAt: [Duration] = []

  init(clock: ScriptedClock, steps: AsyncStream<ContentStep>.Continuation) {
    self.clock = clock
    self.start = clock.now
    self.steps = steps
  }

  func sendDraft(chatID: Int64, draftID: Int64, markdown: String) async -> Bool {
    sentAt.append(start.duration(to: clock.now))
    switch sentAt.count {
    case 1, 2:
      let published = TypingReleaseGate()
      steps.yield(.grow(published))
      await published.awaitRelease()
    case 3:
      steps.yield(.finish)
    default:
      break
    }
    return true
  }
}

@Suite
struct StreamingDraftCadenceTests {
  @Test
  func onlyTheSecondDraftGoesOutOnTheNextProbe() async throws {
    // given
    let (steps, stepSink) = AsyncStream<ContentStep>.makeStream()
    let clock = ScriptedClock.compressed(parkingAt: .seconds(1))
    let drafts = TickStampedDrafts(clock: clock, steps: stepSink)
    let runtime = makeRuntime(
      provider: DraftPacedProvider(steps: steps),
      drafts: drafts,
      streamingEnabled: true,
      clock: clock
    )
    let context = BuildResult(
      messages: [ChatMessage(role: .user, content: "hi")],
      ownerNotices: [],
      hasPrivateDataAccess: false
    )

    // when
    let turn = startTurn {
      try await runtime.runTurn(
        makeTurnRequest(runID: 1, sessionID: 2, chatID: 3, context: context)
      )
    }
    let outcome = try #require(await waitForTurnResult(turn))

    // then
    _ = try requireCompleted(outcome.result)
    let sentAt = await drafts.sentAt
    try #require(sentAt.count >= 3)
    let probe = StreamingTurnRuntime.probeInterval
    #expect(sentAt[1] - sentAt[0] == probe)
    #expect(sentAt[2] - sentAt[1] == probe * StreamingTurnRuntime.minTicksBetweenDrafts)
  }
}
