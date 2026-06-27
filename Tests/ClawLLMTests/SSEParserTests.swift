import Foundation
import Testing

@testable import ClawCore
@testable import ClawLLM

@Suite struct SSEParserTests {
  @Test func parsesDeltasAcrossChunkBoundariesAndDone() throws {
    // given
    var parser = SSEParser()

    // when
    let first = try parser.push(
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"he\"}}]}\n".utf8)
    )
    let second = try parser.push(
      Data(
        "\ndata: {\"choices\":[{\"delta\":{\"content\":\"llo\"},\"finish_reason\":\"stop\"}]}\n\n"
          .utf8
      )
    )
    let third = try parser.push(Data("data: [DONE]\n\n".utf8))

    // then
    #expect(first.isEmpty)
    #expect(second == [.delta("he"), .delta("llo")])
    #expect(third == [.finished(finishReason: "stop", usage: nil, providerCost: nil)])
    #expect(try parser.finish() == nil)
  }

  @Test func doneStopsParsingTrailingEventsInSamePush() throws {
    // given
    var parser = SSEParser()
    let stream = Data(
      ("data: [DONE]\n\n"
        + "data: {\"choices\":[{\"delta\":{\"content\":\"after\"},\"finish_reason\":\"stop\"}]}\n\n"
        + "data: [DONE]\n\n").utf8
    )

    // when
    let events = try parser.push(stream)
    let later = try parser.push(
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"later\"}}]}\n\n".utf8)
    )

    // then
    #expect(events == [.finished(finishReason: nil, usage: nil, providerCost: nil)])
    #expect(later.isEmpty)
    #expect(try parser.finish() == nil)
  }

  @Test func handlesCRLFAndMultilineData() throws {
    // given
    var parser = SSEParser()
    let event = Data(
      (": keep alive\r\n"
        + "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}],\r\n"
        + "data: \"usage\":null}\r\n\r\n").utf8
    )

    // when
    let events = try parser.push(event)

    // then
    #expect(events == [.delta("one")])
  }

  @Test func latchesUsageFromEmptyChoicesChunk() throws {
    // given
    var parser = SSEParser()
    _ = try parser.push(
      Data(
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n".utf8
      )
    )

    // when
    let usageChunk = Data(
      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10,\"cost\":0.0042}}\n\n"
        .utf8
    )
    let events = try parser.push(usageChunk)
    let finished = try parser.push(Data("data: [DONE]\n\n".utf8))

    // then
    #expect(events.isEmpty)
    #expect(
      finished == [
        .finished(
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10),
          providerCost: 0.0042
        )
      ]
    )
  }

  @Test func preservesLatchedProviderCostWhenLaterUsageOmitsCost() throws {
    // given
    var parser = SSEParser()
    _ = try parser.push(
      Data(
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10,\"cost\":0.0042}}\n\n"
          .utf8
      )
    )

    // when
    _ = try parser.push(
      Data(
        "data: {\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":4,\"total_tokens\":12}}\n\n"
          .utf8
      )
    )
    let finished = try parser.push(Data("data: [DONE]\n\n".utf8))

    // then
    #expect(
      finished == [
        .finished(
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 8, completionTokens: 4, totalTokens: 12),
          providerCost: 0.0042
        )
      ]
    )
  }

  @Test func eofWithoutDoneAfterCompleteEventFinishes() throws {
    // given
    var parser = SSEParser()

    // when
    let events = try parser.push(
      Data(
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n".utf8
      )
    )
    let finished = try parser.finish()

    // then
    #expect(events == [.delta("hi")])
    #expect(finished == .finished(finishReason: "stop", usage: nil, providerCost: nil))
  }

  @Test func eofMidEventThrowsTruncated() throws {
    // given
    var parser = SSEParser()
    _ = try parser.push(Data("data: {\"choices\":[".utf8))

    // then
    #expect(throws: SSEParserError.truncatedEvent) {
      _ = try parser.finish()
    }
  }

  @Test func successfulEmptyContentStreamIsValid() throws {
    // given
    var parser = SSEParser()

    // when
    _ = try parser.push(
      Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8)
    )
    let finished = try parser.push(Data("data: [DONE]\n\n".utf8))

    // then
    #expect(finished == [.finished(finishReason: "stop", usage: nil, providerCost: nil)])
  }

  @Test func boundsSingleEventAndBufferedStream() throws {
    // given
    var parser = SSEParser(maxEventBytes: 8, maxBufferedBytes: 64)

    // then
    #expect(throws: SSEParserError.eventTooLarge) {
      _ = try parser.push(Data("data: 123456789\n\n".utf8))
    }
  }

  @Test func boundsBufferedStreamBeforeDelimiter() throws {
    // given
    var parser = SSEParser(maxEventBytes: 128, maxBufferedBytes: 8)

    // then
    #expect(throws: SSEParserError.bufferedStreamTooLarge) {
      _ = try parser.push(Data("data: 123".utf8))
    }
  }

  @Test func boundsAccumulatedContentAcrossManySmallValidDeltas() throws {
    // given
    var parser = SSEParser(
      maxEventBytes: 128,
      maxBufferedBytes: LLMStreamLimits.maxAccumulatedContentBytes,
      maxAccumulatedContentBytes: 5
    )
    let event = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ab\"}}]}\n\n".utf8)

    // when
    _ = try parser.push(event)
    _ = try parser.push(event)

    // then
    #expect(throws: SSEParserError.accumulatedContentTooLarge) {
      _ = try parser.push(event)
    }
  }
}
