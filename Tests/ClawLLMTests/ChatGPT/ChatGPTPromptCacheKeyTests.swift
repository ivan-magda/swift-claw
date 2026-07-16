import ClawCore
import Foundation
import Testing

@testable import ClawLLM

/// The key is asserted through the encoder rather than against the deriving type directly: what the
/// route is actually told to cache under is the body's field, and a key that is right in isolation
/// but never reaches the body would still leave every run cache-cold.
@Suite struct ChatGPTPromptCacheKeyTests {
  /// The key over a known prefix, byte for byte. The expectation was computed from the specified
  /// encoding — length-prefixed UTF-8 segments, first twelve digest bytes as hex — independently of
  /// the Swift that produces it, so the two agreeing means the encoding is the one specified rather
  /// than merely self-consistent.
  @Test func cacheKeyMatchesTheGoldenVector() throws {
    // given
    let request = makeRequest(
      instructions: ["You are helpful.", "Be brief."],
      tools: []
    )

    // when
    let key = try cacheKey(for: request)

    // then
    #expect(key == "swift-claw:cbcece245430edb08f8e6a62")
  }

  /// Two runs of the same static prefix share a cache entry however their sessions differ; the
  /// session travels in a header instead. A key that folded the session in would make every
  /// recurring proactive run cache-cold.
  @Test func cacheKeyIsStableAcrossSessions() throws {
    // given
    let first = makeRequest(
      instructions: ["You are helpful."],
      tools: [clockTool],
      sessionId: "clawd-session-1"
    )
    let second = makeRequest(
      instructions: ["You are helpful."],
      tools: [clockTool],
      sessionId: "clawd-session-2"
    )

    // when
    let firstKey = try cacheKey(for: first)
    let secondKey = try cacheKey(for: second)

    // then
    #expect(firstKey == secondKey)
  }

  /// The registry hands the same tools over in whatever order it iterates, and that order is not
  /// something the owner chose. The body still sends them as given, so the two assertions here are
  /// the whole rule: the key sorts, the array does not.
  @Test func cacheKeyIsStableAcrossToolInsertionOrder() throws {
    // given
    let forward = makeRequest(instructions: ["S"], tools: [webFetchTool, clockTool])
    let reversed = makeRequest(instructions: ["S"], tools: [clockTool, webFetchTool])

    // when
    let forwardBody = try decodeBody(encoder.encode(request: forward))
    let reversedBody = try decodeBody(encoder.encode(request: reversed))

    // then
    #expect(
      forwardBody["prompt_cache_key"] as? String == reversedBody["prompt_cache_key"] as? String
    )
    #expect(toolNames(in: forwardBody) == ["web_fetch", "clock"])
    #expect(toolNames(in: reversedBody) == ["clock", "web_fetch"])
  }

  @Test func cacheKeyChangesWithInstructions() throws {
    // given
    let original = makeRequest(instructions: ["You are helpful.", "Be brief."], tools: [])
    let altered = makeRequest(instructions: ["You are helpful.", "Be terse."], tools: [])

    // when
    let originalKey = try cacheKey(for: original)
    let alteredKey = try cacheKey(for: altered)

    // then
    #expect(originalKey != alteredKey)
    #expect(originalKey == "swift-claw:cbcece245430edb08f8e6a62")
    #expect(alteredKey == "swift-claw:74df22596ffe729837abfc45")
  }

  @Test func cacheKeyChangesWithToolSchema() throws {
    // given
    let original = makeRequest(instructions: ["S"], tools: [clockTool])
    let altered = makeRequest(
      instructions: ["S"],
      tools: [
        ToolDefinition(
          name: "clock",
          description: "Read the clock.",
          parameters: .object([
            "type": .string("object"),
            "properties": .object(["tz": .object(["type": .string("string")])]),
          ]),
          egressClass: .none,
          riskLevel: .safe
        )
      ]
    )

    // when
    let originalKey = try cacheKey(for: original)
    let alteredKey = try cacheKey(for: altered)

    // then
    #expect(originalKey != alteredKey)
  }

  @Test func cacheKeyChangesWithToolDescription() throws {
    // given
    let original = makeRequest(instructions: ["S"], tools: [clockTool])
    let altered = makeRequest(
      instructions: ["S"],
      tools: [
        ToolDefinition(
          name: "clock",
          description: "Read the wall clock.",
          parameters: .object(["type": .string("object")]),
          egressClass: .none,
          riskLevel: .safe
        )
      ]
    )

    // when
    let originalKey = try cacheKey(for: original)
    let alteredKey = try cacheKey(for: altered)

    // then
    #expect(originalKey != alteredKey)
  }

  /// Conversation text is not part of the prefix at all, so a turn cannot move the key off the
  /// entry its instructions and tools earned.
  @Test func cacheKeyIgnoresConversationText() throws {
    // given
    let first = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .system, content: "S"),
        ChatMessage(role: .user, content: "what time is it"),
      ],
      maxOutputTokens: 4096
    )
    let second = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .system, content: "S"),
        ChatMessage(role: .user, content: "something else entirely"),
        ChatMessage(role: .assistant, content: "sure"),
      ],
      maxOutputTokens: 4096
    )

    // when
    let firstKey = try cacheKey(for: first)
    let secondKey = try cacheKey(for: second)

    // then
    #expect(firstKey == secondKey)
  }

  /// The key travels to the vendor as a cache hint, so it must carry no prompt text. The shape
  /// assertion is what makes that structural: a value that is exactly a fixed prefix and twenty-four
  /// hex characters has nowhere to hide the phrases the absence checks look for.
  @Test func cacheKeyCarriesNoPromptText() throws {
    // given
    let phrase = "Zanzibar-Quartzite-Owner-Secret"
    let request = makeRequest(
      instructions: [phrase],
      tools: [
        ToolDefinition(
          name: "clock",
          description: "Vermillion-Toolbox-Description",
          parameters: .object(["type": .string("object")]),
          egressClass: .none,
          riskLevel: .safe
        )
      ]
    )

    // when
    let key = try cacheKey(for: request)

    // then
    #expect(key.contains(phrase) == false)
    #expect(key.contains("Zanzibar") == false)
    #expect(key.contains("Vermillion") == false)
    #expect(key.hasPrefix("swift-claw:"))
    let digest = key.dropFirst("swift-claw:".count)
    #expect(digest.count == 24)
    #expect(
      digest.allSatisfy { character in
        character.isHexDigit && character.isUppercase == false
      }
    )
  }

  /// Length prefixes are what make the encoding injective. Without them these two requests hash the
  /// same bytes — empty instructions followed by one tool's JSON, against that same JSON as the
  /// instructions and no tools at all — and would silently share a cache entry.
  @Test func lengthPrefixesSeparateInstructionsFromToolDefinitions() throws {
    // given
    let toolJSON = """
      {"description":"d","name":"a","parameters":{"type":"object"},"strict":false,\
      "type":"function"}
      """
    let asTool = ChatRequest(
      model: "gpt-5",
      messages: [ChatMessage(role: .user, content: "hello")],
      maxOutputTokens: 4096,
      tools: [
        ToolDefinition(
          name: "a",
          description: "d",
          parameters: .object(["type": .string("object")]),
          egressClass: .none,
          riskLevel: .safe
        )
      ]
    )
    let asInstructions = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .system, content: toolJSON),
        ChatMessage(role: .user, content: "hello"),
      ],
      maxOutputTokens: 4096
    )

    // when
    let toolKey = try cacheKey(for: asTool)
    let instructionsKey = try cacheKey(for: asInstructions)

    // then
    #expect(toolKey != instructionsKey)
    #expect(toolKey == "swift-claw:28c419fd2874b1f5808b07c6")
    #expect(instructionsKey == "swift-claw:dbbd6d92b104190226e3108d")
  }
}

// MARK: - Fixtures

extension ChatGPTPromptCacheKeyTests {
  fileprivate var encoder: ChatGPTResponsesRequestEncoder { ChatGPTResponsesRequestEncoder() }

  fileprivate var clockTool: ToolDefinition {
    ToolDefinition(
      name: "clock",
      description: "Read the clock.",
      parameters: .object(["type": .string("object")]),
      egressClass: .none,
      riskLevel: .safe
    )
  }

  fileprivate var webFetchTool: ToolDefinition {
    ToolDefinition(
      name: "web_fetch",
      description: "Fetch a URL.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["url": .object(["type": .string("string")])]),
        "required": .array([.string("url")]),
      ]),
      egressClass: .arbitraryDestination,
      riskLevel: .ask
    )
  }

  fileprivate func makeRequest(
    instructions: [String],
    tools: [ToolDefinition],
    sessionId: String? = nil
  ) -> ChatRequest {
    let system = instructions.map { text in
      ChatMessage(role: .system, content: text)
    }
    return ChatRequest(
      model: "gpt-5",
      messages: system + [ChatMessage(role: .user, content: "hello")],
      maxOutputTokens: 4096,
      tools: tools,
      sessionId: sessionId
    )
  }

  fileprivate func cacheKey(for request: ChatRequest) throws -> String {
    let body = try decodeBody(encoder.encode(request: request))
    return try #require(body["prompt_cache_key"] as? String)
  }

  fileprivate func toolNames(in body: [String: Any]) -> [String] {
    let tools = body["tools"] as? [[String: Any]] ?? []
    return tools.compactMap { tool in
      tool["name"] as? String
    }
  }
}
