import Foundation
import Testing

@testable import ClawCore

@Suite
struct ChatContractToolTests {
  @Test
  func estimatorCountsToolCallArgumentsText() {
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
