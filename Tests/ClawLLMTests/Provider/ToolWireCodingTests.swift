import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawLLM

@Suite
struct ToolWireCodingTests {
  /// These tests only exercise encoding and parsing, so the transport is never reached; the empty
  /// script makes an accidental dispatch fail loudly rather than look like a pass.
  private func wireProvider() -> OpenAICompatibleProvider {
    makeProvider(
      config: makeConfig(
        baseURL: "http://localhost/v1",
        maxTokensField: .maxTokens,
        apiKey: "",
        model: "m",
        maxOutputTokens: 100,
        retryBudget: 1
      ),
      http: ScriptedHTTPExecutor([])
    )
  }

  private func encodeToDictionary(_ request: ChatRequest) throws -> [String: Any] {
    let data = try wireProvider().encode(request: request)
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
  }

  @Test
  func requestEncodesToolsArray() throws {
    // given
    let definition = ToolDefinition(
      name: "web_fetch",
      description: "Fetch a public URL.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["url": .object(["type": .string("string")])]),
        "required": .array([.string("url")]),
      ]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe
    )
    let request = ChatRequest(
      model: "m",
      messages: [ChatMessage(role: .user, content: "go")],
      maxOutputTokens: 100,
      tools: [definition]
    )

    // when
    let payload = try encodeToDictionary(request)

    // then
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["type"] as? String == "function")
    let function = try #require(tools[0]["function"] as? [String: Any])
    #expect(function["name"] as? String == "web_fetch")
    let parameters = try #require(function["parameters"] as? [String: Any])
    #expect(parameters["type"] as? String == "object")
  }

  @Test
  func toollessRequestOmitsToolsKey() throws {
    // given
    let request = ChatRequest(
      model: "m",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 10
    )

    // when
    let payload = try encodeToDictionary(request)

    // then
    #expect(payload["tools"] == nil)
  }

  @Test
  func assistantProposalAndToolResultEncodeTheExchangeShape() throws {
    // given — an assistant anchor (empty content) and its tool result message
    let request = ChatRequest(
      model: "m",
      messages: [
        ChatMessage(role: .user, content: "read it"),
        ChatMessage(
          role: .assistant,
          content: "",
          toolCalls: [
            ToolCall(
              id: "call_1",
              name: "web_fetch",
              argumentsJSON: #"{"url":"https://e.example/"}"#
            ),
          ]
        ),
        ChatMessage(role: .tool, content: "page text", toolCallID: "call_1"),
      ],
      maxOutputTokens: 100
    )

    // when
    let payload = try encodeToDictionary(request)

    // then
    let messages = try #require(payload["messages"] as? [[String: Any]])
    let anchor = messages[1]
    #expect(anchor["role"] as? String == "assistant")
    #expect(anchor["content"] == nil)  // empty content + tool_calls → omitted
    let calls = try #require(anchor["tool_calls"] as? [[String: Any]])
    #expect(calls[0]["id"] as? String == "call_1")
    #expect(calls[0]["type"] as? String == "function")
    let function = try #require(calls[0]["function"] as? [String: Any])
    #expect(function["name"] as? String == "web_fetch")
    #expect(function["arguments"] as? String == #"{"url":"https://e.example/"}"#)
    let toolMessage = messages[2]
    #expect(toolMessage["role"] as? String == "tool")
    #expect(toolMessage["tool_call_id"] as? String == "call_1")
    #expect(toolMessage["content"] as? String == "page text")
  }

  @Test
  func responseDecodesToolCallsAndFinishReason() throws {
    // given — a captured-shape tool-call response body
    let fixture = #"""
      {
        "choices": [{
          "message": {
            "content": null,
            "tool_calls": [{
              "id": "call_9",
              "type": "function",
              "function": {"name": "web_search", "arguments": "{\"query\":\"swift\"}"}
            }]
          },
          "finish_reason": "tool_calls"
        }],
        "usage": {"prompt_tokens": 12, "completion_tokens": 7, "total_tokens": 19}
      }
      """#

    // when
    let response = try wireProvider().parse(
      result: HTTPResult(statusCode: 200, headers: [:], body: Data(fixture.utf8)),
      redactor: SecretRedactor(secretValues: [])
    )

    // then
    #expect(response.finishReason == "tool_calls")
    #expect(response.content.isEmpty)
    #expect(
      response.toolCalls == [
        ToolCall(id: "call_9", name: "web_search", argumentsJSON: #"{"query":"swift"}"#),
      ]
    )
  }

  @Test
  func toolCallMissingIDIsDropped() throws {
    // given — a tool_calls entry that omits id (malformed provider response)
    let fixture = #"""
      {
        "choices": [{
          "message": {
            "content": null,
            "tool_calls": [{
              "type": "function",
              "function": {"name": "web_search", "arguments": "{}"}
            }]
          },
          "finish_reason": "tool_calls"
        }]
      }
      """#

    // when
    let response = try wireProvider().parse(
      result: HTTPResult(statusCode: 200, headers: [:], body: Data(fixture.utf8)),
      redactor: SecretRedactor(secretValues: [])
    )

    // then — dropped, not crashed
    #expect(response.toolCalls.isEmpty)
  }

  @Test
  func toolCallMissingFunctionNameIsDropped() throws {
    // given — a tool_calls entry that omits function.name
    let fixture = #"""
      {
        "choices": [{
          "message": {
            "content": null,
            "tool_calls": [{
              "id": "call_1",
              "type": "function",
              "function": {"arguments": "{}"}
            }]
          },
          "finish_reason": "tool_calls"
        }]
      }
      """#

    // when
    let response = try wireProvider().parse(
      result: HTTPResult(statusCode: 200, headers: [:], body: Data(fixture.utf8)),
      redactor: SecretRedactor(secretValues: [])
    )

    // then
    #expect(response.toolCalls.isEmpty)
  }

  @Test
  func toolCallMissingArgumentsDefaultsToEmptyObject() throws {
    // given — id and name present but the arguments field is absent
    let fixture = #"""
      {
        "choices": [{
          "message": {
            "content": null,
            "tool_calls": [{
              "id": "call_9",
              "type": "function",
              "function": {"name": "web_search"}
            }]
          },
          "finish_reason": "tool_calls"
        }]
      }
      """#

    // when
    let response = try wireProvider().parse(
      result: HTTPResult(statusCode: 200, headers: [:], body: Data(fixture.utf8)),
      redactor: SecretRedactor(secretValues: [])
    )

    // then
    #expect(response.toolCalls == [ToolCall(id: "call_9", name: "web_search", argumentsJSON: "{}")])
  }
}
