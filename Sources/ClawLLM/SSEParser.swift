import ClawCore
import Foundation

public enum SSEParserError: Error, Sendable, Equatable {
  case eventTooLarge
  case bufferedStreamTooLarge
  case truncatedEvent
  case malformedJSON(String)
}

public struct SSEParser: Sendable {
  private let maxEventBytes: Int
  private let maxBufferedBytes: Int
  private var buffer = Data()
  private var sawEvent = false
  private var finished = false
  private var finishReason: String?
  private var usage: ChatUsage?
  private var providerCost: Double?

  public init(maxEventBytes: Int = 256 * 1024, maxBufferedBytes: Int = 4 * 1024 * 1024) {
    self.maxEventBytes = maxEventBytes
    self.maxBufferedBytes = maxBufferedBytes
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
    return .finished(finishReason: finishReason, usage: usage, providerCost: providerCost)
  }

  private mutating func parseEvent(_ data: Data) throws -> [StreamEvent] {
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw SSEParserError.malformedJSON("invalid UTF-8")
    }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let payloadLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
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

    guard !payloadLines.isEmpty else {
      return []
    }

    let payload = payloadLines.joined(separator: "\n")
    if payload == "[DONE]" {
      finished = true
      return [.finished(finishReason: finishReason, usage: usage, providerCost: providerCost)]
    }

    let chunk = try decodeChunk(payload)
    sawEvent = true
    var events: [StreamEvent] = []
    if let chunkUsage = chunk.usage {
      usage = ChatUsage(
        promptTokens: chunkUsage.promptTokens ?? 0,
        completionTokens: chunkUsage.completionTokens ?? 0,
        totalTokens: chunkUsage.totalTokens ?? 0
      )
      if let cost = chunkUsage.cost {
        providerCost = cost
      }
    }

    guard let choice = chunk.choices.first else {
      return events
    }
    if let reason = choice.finishReason {
      finishReason = reason
    }
    if let content = choice.delta?.content {
      events.append(.delta(content))
    }
    return events
  }

  private func decodeChunk(_ payload: String) throws -> Chunk {
    do {
      return try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
    } catch {
      throw SSEParserError.malformedJSON("\(error)")
    }
  }

  private func delimiterRange(in data: Data) -> Range<Data.Index>? {
    let lineFeed = Data([0x0A, 0x0A])
    let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
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

private struct Chunk: Decodable {
  let choices: [Choice]
  let usage: Usage?
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
}

private struct Usage: Decodable {
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
}
