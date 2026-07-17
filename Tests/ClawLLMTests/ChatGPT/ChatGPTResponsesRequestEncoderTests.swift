import ClawCore
import Foundation
import Testing

@testable import ClawLLM

private typealias Support = ChatGPTProviderTestSupport

@Suite struct ChatGPTResponsesRequestEncoderTests {
  /// The whole body, byte for byte, for a request that advertises no tools. Every value here is a
  /// literal rather than a reference to the constant that produced it: an assertion that re-derives
  /// its expectation from the code under test moves with it and pins nothing.
  @Test func requestWithoutToolsEncodesTheGoldenBody() throws {
    // given
    let request = ChatRequest(
      model: "openai-chatgpt/gpt-5",
      messages: [
        ChatMessage(role: .system, content: "You are helpful."),
        ChatMessage(role: .system, content: "Be brief."),
        ChatMessage(role: .user, content: "hello"),
      ],
      maxOutputTokens: 4096
    )

    // when
    let body = try encodeBody(request)

    // then
    #expect(
      body == """
        {"include":["reasoning.encrypted_content"],\
        "input":[\
        {"content":[{"text":"hello","type":"input_text"}],"role":"user","type":"message"}],\
        "instructions":"You are helpful.\\n\\nBe brief.",\
        "model":"gpt-5",\
        "prompt_cache_key":"swift-claw:cbcece245430edb08f8e6a62",\
        "store":false,\
        "stream":true}
        """
    )
  }

  /// The whole body for a request carrying tools and a completed tool round trip. The tools are
  /// supplied unsorted so the array proves it keeps request order while the cache key does not.
  @Test func requestWithToolsEncodesTheGoldenBody() throws {
    // given
    let request = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .system, content: "S"),
        ChatMessage(role: .user, content: "u"),
        ChatMessage(
          role: .assistant,
          content: "thinking out loud",
          toolCalls: [ToolCall(id: "call_1", name: "clock", argumentsJSON: "{}")]
        ),
        ChatMessage(role: .tool, content: "12:00", toolCallId: "call_1"),
        ChatMessage(role: .assistant, content: "It is noon."),
      ],
      maxOutputTokens: 4096,
      tools: [Support.webFetchTool, Support.clockTool]
    )

    // when
    let body = try encodeBody(request)

    // then
    #expect(
      body == """
        {"include":["reasoning.encrypted_content"],\
        "input":[\
        {"content":[{"text":"u","type":"input_text"}],"role":"user","type":"message"},\
        {"content":[{"text":"thinking out loud","type":"output_text"}],\
        "role":"assistant","status":"completed","type":"message"},\
        {"arguments":"{}","call_id":"call_1","name":"clock","type":"function_call"},\
        {"call_id":"call_1","output":"12:00","type":"function_call_output"},\
        {"content":[{"text":"It is noon.","type":"output_text"}],\
        "role":"assistant","status":"completed","type":"message"}],\
        "instructions":"S",\
        "model":"gpt-5",\
        "parallel_tool_calls":true,\
        "prompt_cache_key":"swift-claw:fd25691adfb5ff2a3c9ef65a",\
        "store":false,\
        "stream":true,\
        "tool_choice":"auto",\
        "tools":[\
        {"description":"Fetch a URL.","name":"web_fetch",\
        "parameters":{"properties":{"url":{"type":"string"}},"required":["url"],"type":"object"},\
        "strict":false,"type":"function"},\
        {"description":"Read the clock.","name":"clock",\
        "parameters":{"type":"object"},"strict":false,"type":"function"}]}
        """
    )
  }

  /// The three tool fields travel together. Both halves are asserted in one test because either one
  /// alone passes for the wrong reason: an encoder that emits nothing satisfies the absence, and one
  /// that always emits satisfies the presence.
  @Test func toolFieldsAppearTogetherAndOnlyWhenToolsExist() throws {
    // given
    let messages = [ChatMessage(role: .user, content: "hello")]
    let without = ChatRequest(model: "gpt-5", messages: messages, maxOutputTokens: 4096)
    let with = ChatRequest(
      model: "gpt-5",
      messages: messages,
      maxOutputTokens: 4096,
      tools: [Support.clockTool]
    )

    // when
    let withoutBody = try decodeBody(encoder.encode(request: without))
    let withBody = try decodeBody(encoder.encode(request: with))

    // then
    #expect(withoutBody["tools"] == nil)
    #expect(withoutBody["tool_choice"] == nil)
    #expect(withoutBody["parallel_tool_calls"] == nil)
    #expect(withBody["tools"] != nil)
    #expect(withBody["tool_choice"] as? String == "auto")
    #expect(withBody["parallel_tool_calls"] as? Bool == true)
  }

  /// A stop string cannot be honored here and must not be quietly dropped, which would change what
  /// the model was asked for. The paired nil case proves the refusal is the stop field's doing
  /// rather than an encoder that refuses everything.
  @Test func nonNilStopStringsAreRefused() throws {
    // given
    let messages = [ChatMessage(role: .user, content: "hello")]
    let stopping = ChatRequest(
      model: "gpt-5",
      messages: messages,
      maxOutputTokens: 4096,
      stop: ["STOP"]
    )
    let permitted = ChatRequest(
      model: "gpt-5",
      messages: messages,
      maxOutputTokens: 4096,
      stop: nil
    )

    // when
    let refusal = try #require(
      #expect(throws: ProviderError.self) {
        try encoder.encode(request: stopping)
      }
    )
    let body = try decodeBody(encoder.encode(request: permitted))

    // then
    guard case .terminal(let status, _) = refusal else {
      Issue.record("expected a terminal refusal, got \(refusal)")
      return
    }
    #expect(status == nil)
    #expect(body["stop"] == nil)
  }

  /// The Codex path honors no output cap, offers no relied-upon stop contract, and is not asked for
  /// a reasoning configuration or a structured-output shape, so none of those fields may appear.
  @Test func unsupportedFieldsAreOmitted() throws {
    // given
    let request = ChatRequest(
      model: "gpt-5",
      messages: [ChatMessage(role: .user, content: "hello")],
      maxOutputTokens: 4096,
      responseFormat: .jsonSchema(name: "draft", schema: .object(["type": .string("object")])),
      sessionId: "clawd-session-7"
    )

    // when
    let body = try decodeBody(encoder.encode(request: request))

    // then
    #expect(body["max_output_tokens"] == nil)
    #expect(body["max_completion_tokens"] == nil)
    #expect(body["max_tokens"] == nil)
    #expect(body["reasoning"] == nil)
    #expect(body["response_format"] == nil)
    #expect(body["text"] == nil)
    #expect(body["stop"] == nil)
    #expect(body["session_id"] == nil)
    // The fields that do belong, so the absences above cannot pass on an empty body.
    #expect(body["model"] as? String == "gpt-5")
    #expect(body["store"] as? Bool == false)
    #expect(body["stream"] as? Bool == true)
    #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
  }

  /// System text is joined wherever it appears in the history, in the order it appears — including
  /// after a user turn, which a filter that only reads a leading run would miss.
  @Test func systemMessagesConcatenateInHistoryOrder() throws {
    // given
    let request = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .system, content: "first"),
        ChatMessage(role: .user, content: "hello"),
        ChatMessage(role: .system, content: "second"),
        ChatMessage(role: .system, content: "third"),
      ],
      maxOutputTokens: 4096
    )

    // when
    let body = try decodeBody(encoder.encode(request: request))

    // then
    #expect(body["instructions"] as? String == "first\n\nsecond\n\nthird")
    // System text becomes instructions rather than an input item, so only the user turn survives.
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input.first?["role"] as? String == "user")
  }

  /// A proposal whose text is empty still has to reach the route as calls: the adapter that replays
  /// reasoning material replaces assistant text, and function calls that rode on that text would
  /// vanish with it.
  @Test func functionCallsSurviveAnAssistantMessageWithNoText() throws {
    // given
    let request = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .user, content: "what time is it"),
        ChatMessage(
          role: .assistant,
          content: "",
          toolCalls: [ToolCall(id: "call_9", name: "clock", argumentsJSON: #"{"tz":"UTC"}"#)]
        ),
      ],
      maxOutputTokens: 4096
    )

    // when
    let body = try decodeBody(encoder.encode(request: request))

    // then
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 2)
    #expect(input.last?["type"] as? String == "function_call")
    #expect(input.last?["call_id"] as? String == "call_9")
    #expect(input.last?["name"] as? String == "clock")
    #expect(input.last?["arguments"] as? String == #"{"tz":"UTC"}"#)
  }

  /// Replay state is the issuing adapter's alone. Rendering it into the prompt would hand opaque
  /// material to the model as text and put it somewhere the daemon promises it never goes.
  @Test func providerStateIsNeverEncodedAsText() throws {
    // given
    let marker = "REPLAY-MARKER-9f2c"
    let request = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .user, content: "hello"),
        ChatMessage(
          role: .assistant,
          content: "visible answer",
          providerState: ProviderExchangeState(
            issuer: "ISSUER-MARKER-9f2c",
            payload: Data(marker.utf8)
          )
        ),
      ],
      maxOutputTokens: 4096
    )

    // when
    let body = try encodeBody(request)

    // then
    #expect(body.contains(marker) == false)
    #expect(body.contains("ISSUER-MARKER") == false)
    #expect(body.contains(marker.data(using: .utf8)?.base64EncodedString() ?? "") == false)
    // The message itself was encoded, so the absences above are the state's and not the message's.
    #expect(body.contains("visible answer"))
  }

  /// An over-cap eviction stamps a turn's replay state empty. Replaying that empty turn would emit no
  /// assistant text, so the ordinary answer the message still holds must fall back to normal encoding
  /// rather than being dropped — and its tool call has to survive the fallback too.
  @Test func anEmptyStampedReplayTurnStillSendsItsAssistantAnswer() throws {
    // given — a history whose assistant turn carries the empty-stamped payload but still holds its
    // answer and a tool call, decoded into the selection the provider would replay
    let profileID = UUID()
    let wireModel = "gpt-5"
    let codec = ChatGPTProviderStateCodec()
    let emptyStamped = try codec.encodeResponseState(
      items: ChatGPTReplayItems(),
      identity: ChatGPTReplayIdentity(profileID: profileID, wireModel: wireModel, epoch: UUID())
    )
    let messages = [
      ChatMessage(role: .user, content: "what time is it"),
      ChatMessage(
        role: .assistant,
        content: "It is noon.",
        toolCalls: [ToolCall(id: "call_1", name: "clock", argumentsJSON: "{}")],
        providerState: emptyStamped
      ),
    ]
    let selection = codec.decodeCompatibleHistory(
      messages: messages,
      profileID: profileID,
      wireModel: wireModel
    )
    // The empty-stamped turn is selected with no replay material — the exact fallback trigger.
    #expect(selection.turns[1]?.hasReplayMaterial == false)
    let request = ChatRequest(
      model: "openai-chatgpt/gpt-5",
      messages: messages,
      maxOutputTokens: 4096
    )

    // when
    let body = try decodeBody(
      encoder.encode(request: request, replaying: selection, includePriorState: true)
    )

    // then — the assistant answer rides the wire as an output_text item, and its call beside it
    let input = try #require(body["input"] as? [[String: Any]])
    let assistant = try #require(
      input.first { entry in
        entry["role"] as? String == "assistant"
      }
    )
    let content = try #require(assistant["content"] as? [[String: Any]])
    #expect(content.first?["type"] as? String == "output_text")
    #expect(content.first?["text"] as? String == "It is noon.")
    let call = try #require(
      input.first { entry in
        entry["type"] as? String == "function_call"
      }
    )
    #expect(call["call_id"] as? String == "call_1")
    #expect(call["name"] as? String == "clock")
  }

  /// A tool result names the call it answers, so the route can pair it with the `function_call` it
  /// was given rather than guessing from position.
  @Test func toolResultsCarryTheirCallIdentity() throws {
    // given
    let request = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .tool, content: "12:00", toolCallId: "call_1")
      ],
      maxOutputTokens: 4096
    )

    // when
    let body = try decodeBody(encoder.encode(request: request))

    // then
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input.first?["type"] as? String == "function_call_output")
    #expect(input.first?["call_id"] as? String == "call_1")
    #expect(input.first?["output"] as? String == "12:00")
  }
}

// MARK: - Fixtures

extension ChatGPTResponsesRequestEncoderTests {
  fileprivate var encoder: ChatGPTResponsesRequestEncoder { ChatGPTResponsesRequestEncoder() }

  fileprivate func encodeBody(_ request: ChatRequest) throws -> String {
    try #require(String(data: encoder.encode(request: request), encoding: .utf8))
  }
}
