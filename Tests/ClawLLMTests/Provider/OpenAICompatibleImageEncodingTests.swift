import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawLLM

@Suite struct OpenAICompatibleImageEncodingTests {
  /// Calls the wire encoder directly. The empty script is not a stub the encoder reaches — it makes
  /// an accidental dispatch throw rather than quietly pass.
  private func encodedBody(for request: ChatRequest) throws -> [String: Any] {
    let provider = makeProvider(config: makeConfig(), http: ScriptedHTTPExecutor([]))
    return try decodeBody(provider.encode(request: request))
  }

  @Test func textOnlyMessagesStillEncodeContentAsAString() throws {
    // given — the compatibility guarantee: no existing turn may change shape on the wire
    let request = ChatRequest(
      model: "gpt-5.4",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 64
    )

    // when
    let body = try encodedBody(for: request)

    // then
    let content = try #require(body["messages"] as? [[String: Any]])[0]["content"]
    #expect(content as? String == "hi")
  }

  @Test func imagePartsEncodeAsAnImageUrlContentArray() throws {
    // given
    let content = MessageContent(parts: [.image(samplePixel), .text("what is this?")])
    let request = ChatRequest(
      model: "gpt-5.4",
      messages: [ChatMessage(role: .user, content: content)],
      maxOutputTokens: 64
    )

    // when
    let body = try encodedBody(for: request)

    // then — image first, and a base64 data URL rather than a remote URL
    let messages = try #require(body["messages"] as? [[String: Any]])
    let parts = try #require(messages[0]["content"] as? [[String: Any]])
    #expect(parts.count == 2)
    #expect(parts[0]["type"] as? String == "image_url")
    let imageURL = try #require(parts[0]["image_url"] as? [String: Any])
    let url = try #require(imageURL["url"] as? String)
    #expect(url.hasPrefix("data:image/jpeg;base64,"))
    // … and the pixels themselves survive the trip, not just the envelope around them
    let carried = try decodedImageBytes(after: "data:image/jpeg;base64,", of: url)
    #expect(carried == samplePixel.data)
    #expect(imageURL["detail"] == nil)
    #expect(parts[1]["type"] as? String == "text")
    #expect(parts[1]["text"] as? String == "what is this?")
  }
}
