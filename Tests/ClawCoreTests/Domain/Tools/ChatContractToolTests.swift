import Foundation
import Testing

@testable import ClawCore

@Suite struct ChatContractToolTests {
  @Test func existingCallSiteShapesStillCompileAndDefaultEmpty() {
    // given / when
    let message = ChatMessage(role: .user, content: "hi")
    let request = ChatRequest(model: "m", messages: [message], maxOutputTokens: 100)
    let response = ChatResponse(
      content: "ok",
      finishReason: "stop",
      usage: nil,
      costFromProvider: nil
    )

    // then
    #expect(message.toolCalls.isEmpty)
    #expect(message.toolCallId == nil)
    #expect(request.tools.isEmpty)
    #expect(response.toolCalls.isEmpty)
  }

  @Test func toolRoleAndToolMessageShape() {
    // given
    let observationMessage = ChatMessage(role: .tool, content: "fetched text", toolCallId: "call_1")

    // then
    #expect(MessageRole.tool.rawValue == "tool")
    #expect(observationMessage.toolCallId == "call_1")
  }

  @Test func estimatorCountsToolCallArgumentsText() {
    // given — identical content; one message re-sends a large tool-call arguments blob
    let argumentsBlob = String(repeating: "x", count: 4_000)
    let plain = ChatMessage(role: .assistant, content: "same")
    let proposing = ChatMessage(
      role: .assistant,
      content: "same",
      toolCalls: [ToolCall(id: "call_1", name: "web_fetch", argumentsJSON: argumentsBlob)]
    )

    // when
    let plainEstimate = TokenEstimator.estimateInputTokens([plain])
    let proposingEstimate = TokenEstimator.estimateInputTokens([proposing])

    // then — the arguments blob must ride inside the estimate (rev.1 L3)
    #expect(proposingEstimate > plainEstimate + 1_000)
  }
}
