import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawLLM

@Suite
struct ChatGPTResponsesProgressTests {
  @Test
  func commentaryAndSummariesNeverBecomeAnswerText() async throws {
    // given
    let rawAnalysis = "PRIVATE ANALYSIS"
    let originalSummaryText = "Checking\n dates"
    let frames = try [
      item("added", index: 0, type: "message", phase: "commentary"),
      delta(index: 0, text: "Looking up "),
      delta(index: 0, text: "dates"),
      item("done", index: 0, type: "message", phase: "commentary", text: "Looking up dates"),
      delta(index: 0, text: "LATE COMMENTARY"),
      item("added", index: 1, type: "reasoning"),
      summary("response.reasoning_summary_text.delta", index: 1, text: "Checking "),
      summary("response.reasoning_summary.delta", index: 1, text: "wrong"),
      summary("response.reasoning_summary_text.done", index: 1, text: originalSummaryText),
      item("added", index: 7, type: "reasoning"),
      summary("response.reasoning_summary.delta", index: 7, text: "Alias draft"),
      summary("response.reasoning_summary.done", index: 7, text: "Alias finished"),
      summary("response.reasoning_summary_text.delta", index: 1, text: "LATE SUMMARY"),
      item("done", index: 1, type: "reasoning", text: originalSummaryText),
      item("done", index: 1, type: "reasoning", text: originalSummaryText),
      item("done", index: 2, type: "reasoning", text: "Completed only"),
      item("added", index: 3, type: "message", phase: "analysis"),
      delta(index: 3, text: rawAnalysis),
      item("done", index: 3, type: "message", phase: "analysis", text: rawAnalysis),
      item("added", index: 4, type: "message", phase: "unknown"),
      delta(index: 4, text: "UNKNOWN PHASE"),
      item("done", index: 5, type: "function_call"),
      item("added", index: 6, type: "message", phase: "final_answer"),
      delta(index: 6, text: "Final answer"),
      item("done", index: 6, type: "message", phase: "final_answer", text: "Final answer"),
      Support.Fixtures.completedTerminal(),
    ]
    let harness = Support.Harness(steps: [.stream(Support.okHead, frames)])

    // when
    var answerDeltas: [String] = []
    var latestTextByItemID: [String: String] = [:]
    var kinds: [String: LLMProgressKind] = [:]
    var completedIDs: Set<String> = []
    var firstSummaryID: String?
    var summaryHistory: [String] = []
    var completedSummaryTexts: [String] = []
    let stream = harness.provider.stream(request: request)
    for try await event in stream {
      switch event {
      case .delta(let text):
        answerDeltas.append(text)
      case .progress(let progress):
        kinds[progress.itemID] = progress.kind
        if progress.kind == .summary, firstSummaryID == nil {
          firstSummaryID = progress.itemID
        }
        switch progress.text {
        case .append(let text):
          #expect(completedIDs.contains(progress.itemID) == false)
          latestTextByItemID[progress.itemID, default: ""] += text
        case .replace(let text):
          #expect(completedIDs.contains(progress.itemID) == false)
          latestTextByItemID[progress.itemID] = text
        case .complete:
          if progress.kind == .summary {
            completedSummaryTexts.append(latestTextByItemID[progress.itemID, default: ""])
          }
          #expect(completedIDs.insert(progress.itemID).inserted)
        }
        if progress.kind == .summary {
          summaryHistory.append(latestTextByItemID[progress.itemID, default: ""])
        }
      case .finished:
        break
      }
    }
    let termination = await stream.awaitTermination()
    guard case .completed(let response) = termination else {
      Issue.record("expected completed response")
      return
    }
    let commentaryIDs = kinds.filter { entry in
      entry.value == .commentary
    }.map(\.key)
    let summaryIDs = kinds.filter { entry in
      entry.value == .summary
    }.map(\.key)
    let visibleItemIDs = Set(kinds.keys)
    let expectedExplanationItemIDs = completedIDs
    let displayedText = latestTextByItemID.values.joined()
    let codec = ChatGPTProviderStateCodec()
    let messages = [
      ChatMessage(
        role: .assistant,
        content: response.content,
        toolCalls: response.toolCalls,
        providerState: response.providerState
      ),
    ]
    let replay = codec.decodeCompatibleHistory(
      messages: messages,
      profileID: Support.fixedProfileID,
      wireModel: "gpt-5"
    )
    let replayedSummaryText = replay.turns[0]?.reasoning.first?.summary.first

    let completeHarness = Support.Harness(steps: [.stream(Support.okHead, frames)])
    let completeResponse = try await completeHarness.provider.complete(request: request)

    // then
    #expect(completeResponse == response)
    #expect(answerDeltas.joined() == "Final answer")
    #expect(response.content == "Final answer")
    #expect(visibleItemIDs == expectedExplanationItemIDs)
    #expect(commentaryIDs.count == 1)
    #expect(summaryIDs.count == 3)
    #expect(summaryHistory.contains("Checking wrong"))
    #expect(completedSummaryTexts.contains("Alias finished"))
    let summaryID = try #require(firstSummaryID)
    #expect(latestTextByItemID[summaryID] == "Checking dates")
    #expect(displayedText.contains(rawAnalysis) == false)
    #expect(displayedText.contains("UNKNOWN PHASE") == false)
    #expect(displayedText.contains("LATE") == false)
    #expect(replayedSummaryText == originalSummaryText)
    #expect(response.toolCalls.map(\.id) == ["call-clock"])
    #expect(response.usage == ChatUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7))
  }

  @Test(arguments: [ProgressBound.textBytes, .itemCount])
  func progressDecodingHonorsExistingOutputBounds(bound: ProgressBound) throws {
    // given — explanation budgets share the bounded Responses decode/accumulate path
    let bounds = ChatGPTResponsesBounds(
      maximumEventBytes: 1_024,
      maximumBufferedBytes: 4_096,
      maximumDataEvents: 32,
      maximumOutputItems: 2,
      maximumAccumulatedOutputBytes: 16
    )
    let frames: [Data]
    switch bound {
    case .textBytes:
      frames = try [
        item("added", index: 0, type: "message", phase: "commentary"),
        delta(index: 0, text: "12345678"),
        delta(index: 0, text: "123456789"),
      ]
    case .itemCount:
      frames = try [
        item("added", index: 0, type: "reasoning"),
        summary("response.reasoning_summary_text.delta", index: 0, text: "one"),
        frame([
          "type": "response.reasoning_summary_text.delta",
          "output_index": 0,
          "summary_index": 1,
          "delta": "two",
        ]),
        item("added", index: 1, type: "message", phase: "commentary"),
        delta(index: 1, text: "three"),
      ]
    }
    var parser = ChatGPTResponsesSSEParser(bounds: bounds)
    var accumulator = ChatGPTResponsesAccumulator(
      identity: ChatGPTReplayIdentity(
        profileID: Support.fixedProfileID,
        wireModel: "gpt-5",
        epoch: Support.fixedEpoch
      ),
      bounds: bounds,
      progressExplanationsEnabled: true
    )

    // when / then — refusing excess explanations never creates answer text or a retryable failure
    #expect(throws: ProviderError.self) {
      for frame in frames {
        _ = try accumulator.consume(parser.push(frame))
      }
    }
    #expect(accumulator.observedCompletionTokens == 0)
  }

  enum ProgressBound: Sendable {
    case textBytes
    case itemCount
  }

}

// MARK: - Progress fixtures

private extension ChatGPTResponsesProgressTests {
  var request: ChatRequest {
    ChatRequest(
      model: "gpt-5",
      messages: [ChatMessage(role: .user, content: "dates")],
      maxOutputTokens: 256,
      tools: [Support.clockTool],
      progressExplanationsEnabled: true
    )
  }

  func item(
    _ suffix: String,
    index: Int,
    type: String,
    phase: String? = nil,
    text: String = ""
  ) throws -> Data {
    var fields: [String: Any] = ["id": "item-\(index)", "type": type]
    if let phase {
      fields["phase"] = phase
    }
    if type == "message" {
      fields["content"] = [["type": "output_text", "text": text]]
    } else if type == "reasoning" {
      fields["encrypted_content"] = "OPAQUE-\(index)"
      fields["summary"] = [["type": "summary_text", "text": text]]
    } else if type == "function_call" {
      fields["call_id"] = "call-clock"
      fields["name"] = "clock"
      fields["arguments"] = "{}"
    }
    return try frame([
      "type": "response.output_item.\(suffix)",
      "output_index": index,
      "item": fields,
    ])
  }

  func delta(index: Int, text: String) throws -> Data {
    try frame(["type": "response.output_text.delta", "output_index": index, "delta": text])
  }

  func summary(_ type: String, index: Int, text: String) throws -> Data {
    let key = type.hasSuffix("done") ? "text" : "delta"
    return try frame([
      "type": type,
      "output_index": index,
      "item_id": "item-\(index)",
      "summary_index": 0,
      key: text,
    ])
  }

  func frame(_ fields: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    return Support.Fixtures.event(String(decoding: data, as: UTF8.self))
  }
}

private typealias Support = ChatGPTProviderTestSupport
