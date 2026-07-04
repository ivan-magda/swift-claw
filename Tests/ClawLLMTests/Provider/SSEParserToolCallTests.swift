import ClawCore
import Foundation
import Testing

@testable import ClawLLM

@Suite struct SSEParserToolCallTests {
  private func pushAll(_ parser: inout SSEParser, _ events: [String]) throws -> [StreamEvent] {
    var collected: [StreamEvent] = []
    for event in events {
      collected.append(contentsOf: try parser.push(Data(("data: " + event + "\n\n").utf8)))
    }
    return collected
  }

  private func finishedToolCalls(_ events: [StreamEvent]) -> [ToolCall]? {
    for event in events {
      if case .finished(_, _, _, let toolCalls) = event {
        return toolCalls
      }
    }
    return nil
  }

  @Test func assemblesSplitIdAndArgumentFragments() throws {
    // given — id/name arrive first; arguments arrive as concatenatable pieces
    var parser = SSEParser()
    let events = try pushAll(
      &parser,
      [
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_fetch","arguments":""}}]}}]}"#,
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"url\":"}}]}}]}"#,
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"https://e.example/\"}"}}]}}],"usage":null}"#,
        #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        "[DONE]",
      ]
    )

    // then — nothing emitted per-fragment; one assembled call on .finished
    let toolCalls = finishedToolCalls(events)
    #expect(
      toolCalls == [
        ToolCall(id: "call_1", name: "web_fetch", argumentsJSON: #"{"url":"https://e.example/"}"#)
      ]
    )
    #expect(events.filter { if case .delta = $0 { true } else { false } }.isEmpty)
  }

  @Test func assemblesMultipleIndicesInOrder() throws {
    // given
    var parser = SSEParser()
    let events = try pushAll(
      &parser,
      [
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"web_search","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"file_read","arguments":"{}"}}]}}]}"#,
        "[DONE]",
      ]
    )

    // then
    #expect(finishedToolCalls(events)?.map(\.id) == ["a", "b"])
  }

  @Test func accumulatedArgumentBytesRespectTheStreamLimit() throws {
    // given — a parser with a tiny accumulation limit
    var parser = SSEParser(maxAccumulatedContentBytes: 64)
    let hugeArguments = String(repeating: "x", count: 128)

    // when / then
    #expect(throws: SSEParserError.accumulatedContentTooLarge) {
      _ = try parser.push(
        Data(
          ("data: "
            + #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"n","arguments":"\#(hugeArguments)"}}]}}]}"#
            + "\n\n").utf8
        )
      )
    }
  }

  @Test func textDeltasStillStreamAlongsideToolFragments() throws {
    // given
    var parser = SSEParser()
    let events = try pushAll(
      &parser,
      [
        #"{"choices":[{"delta":{"content":"Let me check."}}]}"#,
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"web_fetch","arguments":"{}"}}]}}]}"#,
        "[DONE]",
      ]
    )

    // then
    #expect(events.contains(.delta("Let me check.")))
    #expect(finishedToolCalls(events)?.count == 1)
  }

  @Test func eofWithoutFinishedYieldsNoToolCalls() throws {
    // given — deltas then EOF (no [DONE]): the runtime treats this as a complete text reply
    var parser = SSEParser()
    _ = try parser.push(Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n".utf8))

    // when
    let finished = try parser.finish()

    // then
    if case .finished(_, _, _, let toolCalls)? = finished {
      #expect(toolCalls.isEmpty)
    } else {
      Issue.record("expected a finished event")
    }
  }
}
