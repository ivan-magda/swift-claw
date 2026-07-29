import ClawCore
import Foundation
import Testing

@testable import ClawLLM

@Suite struct ChatGPTImageEncodingTests {
  @Test func textOnlyUserMessagesStillEncodeAsInputText() throws {
    // given
    let request = ChatRequest(
      model: "gpt-5.6-sol",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 64
    )

    // when
    let body = try encodedBody(for: request)

    // then
    let input = try #require(body["input"] as? [[String: Any]])
    let parts = try #require(input[0]["content"] as? [[String: Any]])
    #expect(parts.count == 1)
    #expect(parts[0]["type"] as? String == "input_text")
    #expect(parts[0]["text"] as? String == "hi")
    #expect(parts[0]["image_url"] == nil)
  }

  @Test func imagePartsEncodeAsInputImageWithAStringUrl() throws {
    // given
    let content = MessageContent(parts: [.image(samplePixel), .text("what is this?")])
    let request = ChatRequest(
      model: "gpt-5.6-sol",
      messages: [ChatMessage(role: .user, content: content)],
      maxOutputTokens: 64
    )

    // when
    let body = try encodedBody(for: request)

    // then — image_url is a plain string here, unlike Chat Completions' nested object
    let input = try #require(body["input"] as? [[String: Any]])
    let parts = try #require(input[0]["content"] as? [[String: Any]])
    #expect(parts.count == 2)
    #expect(parts[0]["type"] as? String == "input_image")
    let url = try #require(parts[0]["image_url"] as? String)
    #expect(url.hasPrefix("data:image/jpeg;base64,"))
    // … and the pixels themselves survive the trip, not just the envelope around them
    let carried = try decodedImageBytes(after: "data:image/jpeg;base64,", of: url)
    #expect(carried == samplePixel.data)
    #expect(parts[0]["detail"] == nil)
    // The unused payload field is absent rather than null: the probed route reads a part by the
    // field its type names, and a null there is not what the Codex client sends.
    #expect(parts[0]["text"] == nil)
    #expect(parts[1]["type"] as? String == "input_text")
    #expect(parts[1]["text"] as? String == "what is this?")
    #expect(parts[1]["image_url"] == nil)
  }

  /// Several text parts are still one `input_text` part, and carry no image machinery: the branch is
  /// on whether images exist, not on whether the content is a lone text part.
  @Test func multipleTextPartsWithoutAnImageStayOneInputText() throws {
    // given
    let content = MessageContent(parts: [.text("first"), .text("second")])
    let request = ChatRequest(
      model: "gpt-5.6-sol",
      messages: [ChatMessage(role: .user, content: content)],
      maxOutputTokens: 64
    )

    // when
    let body = try encodedBody(for: request)

    // then
    let input = try #require(body["input"] as? [[String: Any]])
    let parts = try #require(input[0]["content"] as? [[String: Any]])
    #expect(parts.count == 1)
    #expect(parts[0]["type"] as? String == "input_text")
    #expect(parts[0]["text"] as? String == "first\nsecond")
  }
}

// MARK: - Fixtures

extension ChatGPTImageEncodingTests {
  fileprivate func encodedBody(for request: ChatRequest) throws -> [String: Any] {
    try decodeBody(ChatGPTResponsesRequestEncoder().encode(request: request))
  }
}
