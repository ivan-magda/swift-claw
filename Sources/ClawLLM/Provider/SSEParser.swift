import ClawCore
import Foundation

public enum SSEParserError: Error, Sendable, Equatable {
  case eventTooLarge
  case bufferedStreamTooLarge
  case accumulatedContentTooLarge
  case truncatedEvent
  case malformedJSON(String)
}

public struct SSEParser: Sendable {
  private let maxEventBytes: Int
  private let maxBufferedBytes: Int
  private let maxAccumulatedContentBytes: Int

  private var buffer = Data()
  private var accumulatedContentBytes = 0

  /// The visible reply assembled from the deltas as they are emitted, so the terminal can state the
  /// whole reply rather than leave a consumer to stitch it back together.
  private var content = ""

  private var sawEvent = false
  private var finished = false
  private var finishReason: String?

  private var usage: ChatUsage?
  private var providerCost: Double?

  private var toolCallAccumulators: [Int: ToolCallAccumulator] = [:]

  public init(
    maxEventBytes: Int = LLMStreamLimits.maxEventBytes,
    maxBufferedBytes: Int = LLMStreamLimits.maxBufferedBytes,
    maxAccumulatedContentBytes: Int = LLMStreamLimits.maxAccumulatedContentBytes,
    fallbackProviderCost: Double? = nil
  ) {
    self.maxEventBytes = maxEventBytes
    self.maxBufferedBytes = maxBufferedBytes
    self.maxAccumulatedContentBytes = maxAccumulatedContentBytes

    self.providerCost = fallbackProviderCost
  }

  public mutating func push(_ data: Data) throws -> [StreamEvent] {
    guard !finished else {
      return []
    }

    buffer.append(data)
    guard buffer.count <= maxBufferedBytes else {
      throw SSEParserError.bufferedStreamTooLarge
    }

    var events: [StreamEvent] = []
    while let delimiter = delimiterRange(in: buffer) {
      let eventData = Data(buffer[..<delimiter.lowerBound])
      buffer.removeSubrange(..<delimiter.upperBound)

      guard eventData.count <= maxEventBytes else {
        throw SSEParserError.eventTooLarge
      }
      events.append(contentsOf: try parseEvent(eventData))

      if finished {
        buffer.removeAll(keepingCapacity: false)
        return events
      }
    }

    guard buffer.count <= maxEventBytes else {
      throw SSEParserError.eventTooLarge
    }

    return events
  }

  public mutating func finish() throws -> StreamEvent? {
    guard !finished else {
      return nil
    }
    guard buffer.isEmpty else {
      throw SSEParserError.truncatedEvent
    }
    guard sawEvent else {
      return nil
    }

    finished = true
    return finishedEvent
  }

  private mutating func parseEvent(_ data: Data) throws -> [StreamEvent] {
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw SSEParserError.malformedJSON("invalid UTF-8")
    }

    let payloadLines = Self.dataPayloadLines(in: text)
    guard !payloadLines.isEmpty else {
      return []
    }

    let payload = payloadLines.joined(separator: "\n")
    if payload == "[DONE]" {
      finished = true
      return [finishedEvent]
    }

    let chunk = try decodeChunk(payload)
    sawEvent = true
    var events: [StreamEvent] = []
    if let chunkUsage = chunk.usage {
      record(chunkUsage)
    }

    guard let choice = chunk.choices.first else {
      return events
    }

    if let reason = choice.finishReason {
      finishReason = reason
    }

    if let fragments = choice.delta?.toolCalls {
      try accumulate(fragments)
      sawEvent = true
    }

    if let fragment = choice.delta?.content {
      try appendContentBytes(fragment.utf8.count)
      content += fragment
      events.append(.delta(fragment))
    }

    return events
  }

  /// Fragments assembled in index order — emitted only on `.finished`. Drops any
  /// accumulator that never received an id/name (malformed stream) and defaults empty
  /// arguments to `"{}"`, mirroring the blocking path's `parse(result:)` (same rule, two seams).
  private var assembledToolCalls: [ToolCall] {
    toolCallAccumulators.keys.sorted().compactMap { index in
      let accumulator = toolCallAccumulators[index] ?? ToolCallAccumulator()
      guard !accumulator.id.isEmpty, !accumulator.name.isEmpty else {
        return nil
      }
      return ToolCall(
        id: accumulator.id,
        name: accumulator.name,
        argumentsJSON: accumulator.arguments.isEmpty ? "{}" : accumulator.arguments
      )
    }
  }

  private mutating func accumulate(_ fragments: [DeltaToolCall]) throws {
    for fragment in fragments {
      let index = fragment.index ?? 0
      var accumulator = toolCallAccumulators[index] ?? ToolCallAccumulator()
      if let fragmentId = fragment.id, !fragmentId.isEmpty {
        accumulator.id = fragmentId
      }
      if let name = fragment.function?.name, !name.isEmpty {
        accumulator.name = name
      }
      if let arguments = fragment.function?.arguments {
        try appendContentBytes(arguments.utf8.count)
        accumulator.arguments += arguments
      }
      toolCallAccumulators[index] = accumulator
    }
  }

  private mutating func appendContentBytes(_ byteCount: Int) throws {
    guard byteCount <= maxAccumulatedContentBytes - accumulatedContentBytes else {
      throw SSEParserError.accumulatedContentTooLarge
    }
    accumulatedContentBytes += byteCount
  }

  private func decodeChunk(_ payload: String) throws -> Chunk {
    do {
      return try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
    } catch {
      throw SSEParserError.malformedJSON("\(error)")
    }
  }

  private func delimiterRange(in data: Data) -> Range<Data.Index>? {
    let lineFeed = Data([0x0A, 0x0A])  // \n\n
    let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
    let lfRange = data.range(of: lineFeed)
    let crlfRange = data.range(of: crlf)

    switch (lfRange, crlfRange) {
    case (nil, nil):
      return nil
    case (.some(let range), nil):
      return range
    case (nil, .some(let range)):
      return range
    case (.some(let left), .some(let right)):
      return left.lowerBound < right.lowerBound ? left : right
    }
  }
}

// MARK: - Event Assembly

extension SSEParser {
  /// The reply built from everything accumulated so far. A server that closes without a `[DONE]`
  /// still has one, which is what lets the caller state an outcome for a stream that simply ended.
  public var assembledResponse: ChatResponse {
    ChatResponse(
      content: content,
      finishReason: finishReason,
      usage: usage,
      costFromProvider: providerCost,
      toolCalls: assembledToolCalls
    )
  }

  /// A lower bound on what the reply has been billed for so far, for a caller accounting for an
  /// attempt that may not reach its terminal.
  public var observedCompletionTokens: Int {
    usage?.completionTokens ?? 0
  }
}

private extension SSEParser {
  /// The terminal event — one construction shared by `finish()` and the `[DONE]` sentinel so the two
  /// paths can never drift.
  var finishedEvent: StreamEvent {
    .finished(assembledResponse)
  }

  /// The `data:` field values of one SSE event: comments (`:`) and non-`data` fields are dropped,
  /// a single leading space after the colon is stripped, per the SSE field-parsing rules.
  static func dataPayloadLines(in text: String) -> [String] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    return normalized.split(separator: "\n", omittingEmptySubsequences: false)
      .compactMap { rawLine -> String? in
        var line = String(rawLine)

        if line.last == "\r" {
          line.removeLast()
        }

        if line.hasPrefix(":") {
          return nil
        }

        guard line.hasPrefix("data:") else {
          return nil
        }
        var value = String(line.dropFirst(5))

        if value.first == " " {
          value.removeFirst()
        }

        return value
      }
  }

  mutating func record(_ chunkUsage: WireUsage) {
    usage = chunkUsage.toChatUsage()
    if let cost = chunkUsage.cost {
      providerCost = cost
    }
  }
}

private struct Chunk: Decodable {
  let choices: [Choice]
  let usage: WireUsage?
}

private struct Choice: Decodable {
  let delta: Delta?
  let finishReason: String?

  enum CodingKeys: String, CodingKey {
    case delta
    case finishReason = "finish_reason"
  }
}

private struct Delta: Decodable {
  let content: String?
  // swiftlint:disable:next discouraged_optional_collection
  let toolCalls: [DeltaToolCall]?

  enum CodingKeys: String, CodingKey {
    case content
    case toolCalls = "tool_calls"
  }
}

private struct DeltaToolCall: Decodable {
  struct Function: Decodable {
    let name: String?
    let arguments: String?
  }

  let index: Int?
  let id: String?
  let function: Function?
}

private struct ToolCallAccumulator {
  var id = ""
  var name = ""
  var arguments = ""
}

/// The OpenAI-compatible `usage` object, shared by the blocking (`ResponseBody`) and streaming
/// (`Chunk`) decoders so the two seams decode identical bytes into the same shape and can't drift.
/// Absent counts fold to zero in `toChatUsage()`; `cost` is the OpenRouter per-response cost.
struct WireUsage: Decodable {
  let promptTokens: Int?
  let completionTokens: Int?
  let totalTokens: Int?
  let cost: Double?

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
    case cost
  }

  func toChatUsage() -> ChatUsage {
    ChatUsage(
      promptTokens: promptTokens ?? 0,
      completionTokens: completionTokens ?? 0,
      totalTokens: totalTokens ?? 0
    )
  }
}
