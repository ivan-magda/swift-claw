import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawLLM

@Suite
struct CompatibleProgressTests {
  @Test(arguments: [true, false])
  func onlyTypedSummaryDetailsReachProgress(enabled: Bool) async throws {
    // given
    let answer = "The date is October 1"
    let rawReasoning = "PRIVATE REASONING"
    let expectedID = "summary-date"
    let expectedUsage = ChatUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10)
    let frames = try [
      frame(["delta": ["reasoning": rawReasoning, "reasoning_content": rawReasoning]]),
      frame([
        "delta": [
          "reasoning_details": [
            detail("Checking ", id: expectedID, index: nil),
            ["type": "reasoning.text", "text": rawReasoning],
            ["type": "reasoning.encrypted", "data": "ENCRYPTED"],
            ["type": "reasoning.unknown", "summary": "UNKNOWN"],
            ["type": "reasoning.summary", "summary": 42],
            42,
          ],
        ],
      ]),
      frame(["delta": ["content": answer, "reasoning_details": "malformed"]]),
      frame(["delta": ["reasoning_details": [detail("dates", id: expectedID)]]]),
      frame([
        "delta": [
          "reasoning_details": [
            [
              "type": "reasoning.summary",
              "summary": "dates",
              "index": 0,
            ],
          ],
        ],
      ]),
      frame([
        "message": [
          "reasoning_details": [
            [
              "type": "reasoning.summary",
              "summary": "Checking dates",
              "id": expectedID,
            ],
          ],
        ],
      ]),
      frame(["message": ["reasoning_details": [detail("Checking dates", id: expectedID)]]]),
      frame(["delta": ["reasoning_details": [detail("LATE", id: expectedID)]]]),
      frame(
        ["finish_reason": "stop"],
        usage: [
          "prompt_tokens": 7,
          "completion_tokens": 3,
          "total_tokens": 10,
        ]
      ),
      done,
    ]
    let executor = ScriptedHTTPExecutor([.stream(okHead, frames)])
    let provider = makeProvider(config: makeConfig(apiKey: ""), http: executor)

    // when
    let (events, thrown, terminal) = await drain(
      provider.stream(request: request(enabled: enabled))
    )
    let response = try completed(terminal)
    let summaryEvents = events.compactMap { event -> LLMProgressEvent? in
      guard case .progress(let progress) = event else {
        return nil
      }
      return progress
    }
    let displayedText = summaryEvents.compactMap { progress -> String? in
      switch progress.text {
      case .append(let text), .replace(let text):
        return text
      case .complete:
        return nil
      }
    }.joined()
    let latestSummary = rendered(summaryEvents)
    let requestBody = try decodeBody(try #require(await executor.lastBody))

    // then
    #expect(thrown == nil)
    #expect(response.content == answer)
    #expect(response.usage == expectedUsage)
    #expect(
      summaryEvents.map(\.itemID).allSatisfy {
        $0 == expectedID
      }
    )
    #expect(
      summaryEvents.allSatisfy {
        $0.kind == .summary
      }
    )
    #expect(displayedText.contains(rawReasoning) == false)
    #expect(displayedText.contains("ENCRYPTED") == false)
    #expect(displayedText.contains("UNKNOWN") == false)
    #expect(displayedText.contains("LATE") == false)
    #expect(requestBody["reasoning"] == nil)
    if enabled {
      #expect(latestSummary == "Checking dates")
      #expect(displayedText.contains("Checking datesdates"))
      #expect(
        summaryEvents.filter {
          $0.text == .complete
        }.count == 1
      )
    } else {
      #expect(summaryEvents.isEmpty)
    }
  }

  @Test
  func splitCredentialsAreRedactedBeforePublication() async throws {
    // given
    let secret = "sk-line\nkey"
    let prefix = String(repeating: "x", count: 170) + " "
    let frames = try [
      frame(["delta": ["reasoning_details": [detail(prefix + "sk-line\n", id: "safe")]]]),
      frame(["delta": ["reasoning_details": [detail("key sk-line", id: "safe")]]]),
      frame(["delta": ["reasoning_details": [detail(" key ready", id: "safe")]]]),
      frame(["delta": ["content": "answer"]]),
      done,
    ]
    let executor = ScriptedHTTPExecutor([.stream(okHead, frames)])
    let credentials = ScriptedLLMCredentialSource(redactionValues: [secret])
    let provider = makeProvider(config: makeConfig(), http: executor, credentials: credentials)

    // when
    let (events, _, terminal) = await drain(provider.stream(request: request()))
    let progress = events.compactMap { event -> LLMProgressEvent? in
      guard case .progress(let value) = event else {
        return nil
      }
      return value
    }
    let displayed = rendered(progress)

    // then
    #expect(try completed(terminal).content == "answer")
    #expect(
      displayed == prefix + SecretRedactor.replacement + " "
        + SecretRedactor.replacement + " ready"
    )
  }

  @Test
  func terminalProgressFailurePreservesRecognizedCompletion() async throws {
    // given — exact redaction can expand a bounded wire summary beyond the progress channel budget
    let count =
      LLMEventBufferLimits.providerDefault.maximumDeltaBytes
      / SecretRedactor.replacement.utf8.count + 1
    let explanation = try frame([
      "delta": [
        "reasoning_details": [
          detail(String(repeating: "x", count: count), id: "safe"),
        ],
      ],
    ])
    let answer = try frame(
      ["delta": ["content": "answer"]],
      usage: [
        "prompt_tokens": 7,
        "completion_tokens": 3,
        "total_tokens": 10,
      ]
    )
    let batch = explanation + answer + done
    let executor = ScriptedHTTPExecutor([.stream(okHead, [batch])])
    let provider = makeProvider(
      config: makeConfig(),
      http: executor,
      credentials: ScriptedLLMCredentialSource(redactionValues: ["x"])
    )

    // when — sendProgress refuses the expanded explanation after the terminal was decoded
    let (_, thrown, terminal) = await drain(provider.stream(request: request()))

    // then
    #expect(thrown == nil)
    #expect(try completed(terminal).content == "answer")
    #expect(
      try completed(terminal).usage
        == ChatUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10)
    )
  }

  @Test
  func indexedSummaryWithoutIDFlushesAtEOF() async throws {
    // given — an indexed summary has neither a provider id nor an explicit completion message
    let frames = try [
      frame([
        "delta": [
          "reasoning_details": [
            [
              "type": "reasoning.summary",
              "summary": "Checking date",
              "index": 2,
              "id": NSNull(),
            ],
          ],
        ],
      ]),
      frame([
        "delta": [
          "reasoning_details": [
            [
              "type": "reasoning.summary",
              "summary": "s",
              "index": 2,
            ],
          ],
        ],
      ]),
      frame(["delta": ["content": "answer"]]),
    ]
    let executor = ScriptedHTTPExecutor([.stream(okHead, frames)])
    let provider = makeProvider(config: makeConfig(), http: executor)

    // when
    let (events, _, terminal) = await drain(provider.stream(request: request()))
    let progress = events.compactMap { event -> LLMProgressEvent? in
      guard case .progress(let value) = event else {
        return nil
      }
      return value
    }

    // then
    #expect(try completed(terminal).content == "answer")
    #expect(rendered(progress) == "Checking dates")
    #expect(Set(progress.map(\.itemID)).count == 1)
    #expect(
      progress.filter {
        $0.text == .complete
      }.count == 1
    )
  }

  @Test
  func summariesShareTheAccumulatedContentLimit() throws {
    // given
    var parser = SSEParser(
      maxAccumulatedContentBytes: 128,
      progressExplanationsEnabled: true
    )
    let summary = try frame([
      "delta": [
        "reasoning_details": [
          detail(String(repeating: "x", count: 64), id: "safe"),
        ],
      ],
    ])

    // when
    _ = try parser.push(summary)

    // then
    #expect(throws: SSEParserError.accumulatedContentTooLarge) {
      _ = try parser.push(summary)
    }
  }

}

// MARK: - Fixtures

private extension CompatibleProgressTests {
  var okHead: HTTPStreamHead {
    HTTPStreamHead(statusCode: 200, headers: [:])
  }

  var done: Data {
    Data("data: [DONE]\n\n".utf8)
  }

  func request(enabled: Bool = true) -> ChatRequest {
    ChatRequest(
      model: "gpt-4o",
      messages: [ChatMessage(role: .user, content: "dates")],
      maxOutputTokens: 256,
      progressExplanationsEnabled: enabled
    )
  }

  func detail(_ summary: String, id: String, index: Int? = 0) -> [String: Any] {
    var fields: [String: Any] = ["type": "reasoning.summary", "summary": summary, "id": id]
    if let index {
      fields["index"] = index
    }
    return fields
  }

  func frame(_ choice: [String: Any], usage: [String: Int] = [:]) throws -> Data {
    var fields: [String: Any] = ["choices": [choice]]
    if !usage.isEmpty {
      fields["usage"] = usage
    }
    let json = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    let text = try #require(String(bytes: json, encoding: .utf8))
    return Data(("data: " + text + "\n\n").utf8)
  }

  func completed(_ termination: LLMStreamTermination) throws -> ChatResponse {
    guard case .completed(let response) = termination else {
      throw CompatibleProgressFailure.expectedCompletion
    }
    return response
  }

  func rendered(_ events: [LLMProgressEvent]) -> String {
    var text = ""
    for event in events {
      switch event.text {
      case .append(let fragment):
        text += fragment
      case .replace(let replacement):
        text = replacement
      case .complete:
        break
      }
    }
    return text
  }
}

private enum CompatibleProgressFailure: Error {
  case expectedCompletion
}
