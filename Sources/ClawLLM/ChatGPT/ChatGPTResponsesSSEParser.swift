import ClawCore
import Foundation

// MARK: - Bounds

/// What one Responses stream may cost to read.
///
/// The route carries its own table rather than borrowing the Chat Completions one. The two speak the
/// same transport but not the same protocol, and a cap that moved for one of them has no business
/// moving for the other: a Responses event carries a whole message item and its encrypted reasoning,
/// where a Chat Completions chunk carries one delta.
enum ChatGPTResponsesBounds {
  static let maximumEventBytes = 2 * 1024 * 1024
  static let maximumBufferedBytes = 4 * 1024 * 1024
  static let maximumDataEvents = 65_536
  static let maximumOutputItems = 1_024

  /// Visible text and tool arguments together — the two accumulations the answer is built from, and
  /// the only two this side can measure what the owner was charged for from.
  static let maximumAccumulatedOutputBytes = 4 * 1024 * 1024
}

// MARK: - Parser

/// Frames a Responses SSE body into the events the route models, and reports when the bytes it has
/// consumed stopped being replayable.
///
/// It decides nothing about the reply. Where an event ends and what it decodes to is all this owns;
/// which event is the terminal, and what the answer is, belongs to the accumulator.
struct ChatGPTResponsesSSEParser: Sendable {
  /// Whether a byte belonging to an SSE `data:` field has been consumed. It closes the automatic-
  /// retry boundary: past this point the server has begun answering, so re-issuing the request could
  /// bill the owner for the same turn twice. It is set from the field's own bytes rather than from a
  /// decoded event, so a fragmented, malformed, or unknown data event closes the boundary just as a
  /// good one does — while framing comments, which carry no answer, never do.
  private(set) var hasSeenDataFieldByte = false

  private var buffer = Data()
  private var dataEventCount = 0
  private var boundary = DataFieldScan()

  init() {}

  mutating func push(_ chunk: Data) throws -> [ChatGPTResponsesEvent] {
    // Scanned before the buffer is bounded: these bytes arrived whatever the parser goes on to make
    // of them, and the boundary only ever answers what the wire has already delivered.
    if hasSeenDataFieldByte == false {
      hasSeenDataFieldByte = boundary.scan(chunk)
    }

    buffer.append(chunk)
    // Bounded before the delimiter is searched for, so a body that would have framed perfectly well
    // still cannot grow the buffer past its cap on the way to being drained.
    guard buffer.count <= ChatGPTResponsesBounds.maximumBufferedBytes else {
      throw Self.bufferedStreamTooLarge
    }

    var events: [ChatGPTResponsesEvent] = []
    // The consumed prefix is dropped once, at the end, rather than per event. Removing each event as
    // it is framed would re-copy the whole remaining buffer every time, which turns one large
    // delivery of small events into quadratic work.
    var consumed = buffer.startIndex
    defer {
      buffer.removeSubrange(..<consumed)
    }

    while let delimiter = SSEFraming.delimiterRange(in: buffer[consumed...]) {
      let eventData = buffer[consumed..<delimiter.lowerBound]
      consumed = delimiter.upperBound

      guard eventData.count <= ChatGPTResponsesBounds.maximumEventBytes else {
        throw Self.eventTooLarge
      }
      if let event = try decode(Data(eventData)) {
        events.append(event)
      }
    }

    // An event still waiting for its delimiter is bounded too: a server cannot hold a stream open by
    // simply never ending the event it is sending.
    guard buffer.count - consumed <= ChatGPTResponsesBounds.maximumEventBytes else {
      throw Self.eventTooLarge
    }

    return events
  }
}

// MARK: - Retry Boundary

/// Recognizes the first byte of an SSE `data:` field as it streams past, one line at a time.
///
/// It runs over raw bytes rather than the framed event because the boundary has to close before the
/// delimiter arrives — an event that is still half-delivered has already been generated.
private struct DataFieldScan {
  private static let fieldName = Array("data:".utf8)

  private var matched = 0
  private var isCandidate = true

  /// Whether these bytes carried the first `data:` field byte.
  mutating func scan(_ chunk: Data) -> Bool {
    for byte in chunk {
      guard byte != 0x0A, byte != 0x0D else {
        // A field line with no colon names a field with an empty value, so a bare `data` line is a
        // data field and closes the boundary exactly as a filled one does.
        let wasBareField = isCandidate && matched == Self.fieldName.count - 1
        matched = 0
        isCandidate = true
        if wasBareField {
          return true
        }
        continue
      }
      guard isCandidate else {
        continue
      }
      guard byte == Self.fieldName[matched] else {
        // A comment (`:`) or any other field name: this line cannot become a data field.
        isCandidate = false
        continue
      }
      matched += 1
      if matched == Self.fieldName.count {
        return true
      }
    }
    return false
  }
}

// MARK: - Framing Failures

private extension ChatGPTResponsesSSEParser {
  static let bufferedStreamTooLarge = ProviderError.terminal(
    status: nil,
    message:
      "the ChatGPT reply buffered more than \(ChatGPTResponsesBounds.maximumBufferedBytes) bytes"
  )

  static let eventTooLarge = ProviderError.terminal(
    status: nil,
    message: "a ChatGPT reply event exceeded \(ChatGPTResponsesBounds.maximumEventBytes) bytes"
  )

  static let tooManyDataEvents = ProviderError.terminal(
    status: nil,
    message: "the ChatGPT reply sent more than \(ChatGPTResponsesBounds.maximumDataEvents) events"
  )

  static let malformedEvent = ProviderError.terminal(
    status: nil,
    message: "the ChatGPT reply contained an event that could not be read"
  )
}

// MARK: - Event Decoding

private extension ChatGPTResponsesSSEParser {
  /// One framed event, or nil for anything this route does not model — a comment-only event, an
  /// unknown type, or a payload that is not an object with a type at all. Unknown events are data
  /// the backend is entitled to send and this parser is entitled to ignore.
  mutating func decode(_ eventData: Data) throws -> ChatGPTResponsesEvent? {
    guard let text = String(bytes: eventData, encoding: .utf8) else {
      throw Self.malformedEvent
    }
    let payloadLines = SSEFraming.dataPayloadLines(in: text)
    guard payloadLines.isEmpty == false else {
      return nil
    }

    dataEventCount += 1
    guard dataEventCount <= ChatGPTResponsesBounds.maximumDataEvents else {
      throw Self.tooManyDataEvents
    }

    let payload = Data(payloadLines.joined(separator: "\n").utf8)
    guard
      let envelope = try? JSONDecoder().decode(ChatGPTWireEventType.self, from: payload),
      let name = ChatGPTWireEventName(rawValue: envelope.type)
    else {
      return nil
    }

    let event: ChatGPTWireEvent
    do {
      event = try JSONDecoder().decode(ChatGPTWireEvent.self, from: payload)
    } catch {
      throw Self.malformedEvent
    }
    return try Self.mapped(name, event)
  }

  /// A known event in the route's own terms. A known name whose payload does not carry what that
  /// name promises is damage rather than something to ignore, so it fails rather than vanishing.
  static func mapped(
    _ name: ChatGPTWireEventName,
    _ event: ChatGPTWireEvent
  ) throws -> ChatGPTResponsesEvent {
    switch name {
    case .outputItemAdded:
      return .outputItemAdded(index: try index(of: event), item: try item(of: event))
    case .outputItemDone:
      return .outputItemDone(index: try index(of: event), item: try item(of: event))
    case .outputTextDelta:
      return .outputTextDelta(index: try index(of: event), text: try text(of: event))
    case .functionCallArgumentsDelta:
      return .functionCallArgumentsDelta(
        index: try index(of: event),
        callID: event.callID,
        fragment: try text(of: event)
      )
    case .functionCallArgumentsDone:
      guard let arguments = event.arguments else {
        throw malformedEvent
      }
      return .functionCallArgumentsDone(
        index: try index(of: event),
        callID: event.callID,
        arguments: arguments
      )
    case .completed, .done, .incomplete, .failed:
      return .terminal(try terminal(name, event))
    case .error:
      return .streamError(ChatGPTRemoteFailure(event.error))
    }
  }

  static func index(of event: ChatGPTWireEvent) throws -> Int {
    // An item event with no index names nothing the accumulator could place it against.
    guard let index = event.outputIndex, index >= 0 else {
      throw malformedEvent
    }
    return index
  }

  static func item(of event: ChatGPTWireEvent) throws -> ChatGPTStreamItem {
    guard let item = event.item else {
      throw malformedEvent
    }
    return ChatGPTStreamItem(item)
  }

  static func text(of event: ChatGPTWireEvent) throws -> String {
    guard let delta = event.delta else {
      throw malformedEvent
    }
    return delta
  }

  static func terminal(
    _ name: ChatGPTWireEventName,
    _ event: ChatGPTWireEvent
  ) throws -> ChatGPTResponsesTerminal {
    guard let response = event.response, let terminalName = ChatGPTResponsesTerminal.Name(name)
    else {
      throw malformedEvent
    }
    return ChatGPTResponsesTerminal(
      name: terminalName,
      responseID: response.id,
      status: response.status.flatMap(ChatGPTResponsesTerminal.Status.init(rawValue:)),
      incompleteReason: response.incompleteDetails?.reason,
      usage: try response.usage?.toChatUsage(),
      failure: response.error.map(ChatGPTRemoteFailure.init)
    )
  }
}

// MARK: - Route Events

/// One event of a Responses stream, in the terms the accumulator reasons about rather than the
/// terms the wire happens to spell them in.
enum ChatGPTResponsesEvent: Sendable, Equatable {
  case outputItemAdded(index: Int, item: ChatGPTStreamItem)
  case outputItemDone(index: Int, item: ChatGPTStreamItem)
  case outputTextDelta(index: Int, text: String)
  case functionCallArgumentsDelta(index: Int, callID: String?, fragment: String)
  case functionCallArgumentsDone(index: Int, callID: String?, arguments: String)
  case terminal(ChatGPTResponsesTerminal)
  case streamError(ChatGPTRemoteFailure)
}

/// One output item as the stream states it. The server's item ID is deliberately absent: `store:
/// false` means no later request can resolve one, so reading it would only invite persisting a
/// handle to nothing.
struct ChatGPTStreamItem: Sendable, Equatable {
  let type: ChatGPTStreamItemType
  let role: String?
  let status: String?
  let phase: ChatGPTMessagePhase
  let callID: String?
  let name: String?
  let arguments: String?
  let outputText: [String]
  let encryptedContent: String?
  let summary: [String]
}

enum ChatGPTStreamItemType: Sendable, Equatable {
  case message
  case reasoning
  case functionCall
  case other(String)
}

/// Which part of the model's turn a message item is. The route publishes only text the backend
/// stated is the answer; everything else is working material the owner never asked to read.
enum ChatGPTMessagePhase: Sendable, Equatable {
  case unspecified
  case final
  case finalAnswer
  case commentary
  case analysis
  case other(String)

  /// A phase the route has never heard of is not known to be the answer. Publishing it would mean
  /// assuming every future phase name is owner-visible, which is the assumption this filter exists
  /// to refuse.
  var isOwnerVisible: Bool {
    switch self {
    case .unspecified, .final, .finalAnswer:
      return true
    case .commentary, .analysis, .other:
      return false
    }
  }
}

/// A terminal response event: status, ID, usage, and error metadata. Its `output` is never read —
/// the studied backend can send `response.completed.response.output = null` for a stream that
/// produced a perfectly good answer, so the answer is rebuilt from the item events instead.
struct ChatGPTResponsesTerminal: Sendable, Equatable {
  enum Name: Sendable, Equatable {
    case completed
    case incomplete
    case failed
  }

  enum Status: String, Sendable, Equatable {
    case completed
    case incomplete
    case failed
    case cancelled
  }

  let name: Name
  let responseID: String?
  let status: Status?
  let incompleteReason: String?
  let usage: ChatUsage?
  let failure: ChatGPTRemoteFailure?

  /// What the response ended as. The nested status is the meaning; the event name is the fallback
  /// for a backend that omits it or names a state this build has never heard of.
  var effectiveStatus: Status {
    if let status {
      return status
    }
    switch name {
    case .completed:
      return .completed
    case .incomplete:
      return .incomplete
    case .failed:
      return .failed
    }
  }

  /// Whether another terminal says the same thing this one does. `response.done` is an observed
  /// alias for `response.completed`, so a stream that sends both has not contradicted itself.
  func restates(_ other: Self) -> Bool {
    responseID == other.responseID
      && effectiveStatus == other.effectiveStatus
      && incompleteReason == other.incompleteReason
  }
}

/// Vendor-supplied failure metadata, exactly as it arrived. It is raw on purpose: this type is the
/// evidence, and the accumulator that puts it in front of an owner is what owes it a sanitizing
/// pass.
struct ChatGPTRemoteFailure: Sendable, Equatable {
  /// The clean-rejection code the poisoned-replay-state recovery keys on, shared with the head
  /// classifier so the head path and the in-band path recognize the same rejection.
  static let invalidEncryptedContentCode = "invalid_encrypted_content"

  let code: String?
  let message: String?

  /// Whether this failure is the backend refusing the replayed encrypted state. Such a turn can be
  /// re-issued without that state, so it maps to `invalidProviderState` rather than a generic
  /// terminal — the failure downstream turns into actionable `/new` guidance.
  var isInvalidProviderState: Bool {
    code == Self.invalidEncryptedContentCode
  }
}

// MARK: - Wire Types

private enum ChatGPTWireEventName: String {
  case outputItemAdded = "response.output_item.added"
  case outputItemDone = "response.output_item.done"
  case outputTextDelta = "response.output_text.delta"
  case functionCallArgumentsDelta = "response.function_call_arguments.delta"
  case functionCallArgumentsDone = "response.function_call_arguments.done"
  case completed = "response.completed"
  case done = "response.done"
  case incomplete = "response.incomplete"
  case failed = "response.failed"
  case error
}

extension ChatGPTResponsesTerminal.Name {
  /// Nil for a name that does not end a response, so a caller cannot quietly turn a delta into a
  /// terminal by asking. `response.done` is the observed alias for `response.completed`; the two are
  /// the same terminal and must compare as one, or a stream that sends both would read as a stream
  /// that contradicted itself.
  fileprivate init?(_ name: ChatGPTWireEventName) {
    switch name {
    case .completed, .done:
      self = .completed
    case .incomplete:
      self = .incomplete
    case .failed:
      self = .failed
    case .outputItemAdded, .outputItemDone, .outputTextDelta, .functionCallArgumentsDelta,
      .functionCallArgumentsDone, .error:
      return nil
    }
  }
}

/// Read before the event itself so an unknown type is never judged by whether the rest of its
/// payload happens to fit a shape this route made up for it.
private struct ChatGPTWireEventType: Decodable {
  let type: String
}

private struct ChatGPTWireEvent: Decodable {
  let outputIndex: Int?
  let item: ChatGPTWireItem?
  let delta: String?
  let arguments: String?
  let callID: String?
  let response: ChatGPTWireResponse?
  let error: ChatGPTWireError?

  private enum CodingKeys: String, CodingKey {
    case outputIndex = "output_index"
    case item
    case delta
    case arguments
    case callID = "call_id"
    case response
    case error
  }
}

private struct ChatGPTWireItem: Decodable {
  let type: String
  let role: String?
  let status: String?
  let phase: String?
  let callID: String?
  let name: String?
  let arguments: String?
  // Absent and empty are the same thing to every reader below, but they are not the same thing on
  // the wire, and a decoder cannot default a key it was never handed.
  // swiftlint:disable:next discouraged_optional_collection
  let content: [ChatGPTWireItemContent]?
  let encryptedContent: String?
  // swiftlint:disable:next discouraged_optional_collection
  let summary: [JSONValue]?

  private enum CodingKeys: String, CodingKey {
    case type
    case role
    case status
    case phase
    case callID = "call_id"
    case name
    case arguments
    case content
    case encryptedContent = "encrypted_content"
    case summary
  }
}

private struct ChatGPTWireItemContent: Decodable {
  static let outputText = "output_text"

  let type: String
  let text: String?
}

/// The nested response object. `output` is absent by design rather than by oversight: it is the one
/// field a terminal is observed to null out on a good reply, so nothing here may be tempted to read
/// it.
private struct ChatGPTWireResponse: Decodable {
  let id: String?
  let status: String?
  let incompleteDetails: ChatGPTWireIncompleteDetails?
  let usage: ChatGPTWireResponsesUsage?
  let error: ChatGPTWireError?

  private enum CodingKeys: String, CodingKey {
    case id
    case status
    case incompleteDetails = "incomplete_details"
    case usage
    case error
  }
}

private struct ChatGPTWireIncompleteDetails: Decodable {
  static let outputTokenLimit = "max_output_tokens"

  let reason: String?
}

private struct ChatGPTWireError: Decodable {
  let code: String?
  let message: String?
}

/// The route's usage object. A count that is negative, fractional, or too large to be an `Int` is
/// damage rather than accounting, and is refused here so no later reader has to wonder.
private struct ChatGPTWireResponsesUsage: Decodable {
  let inputTokens: Int?
  let outputTokens: Int?
  let totalTokens: Int?

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case totalTokens = "total_tokens"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A fractional or overflowing number fails `Int` decoding outright; a negative one decodes
    // cleanly and has to be refused on its value.
    self.inputTokens = try Self.count(in: container, forKey: .inputTokens)
    self.outputTokens = try Self.count(in: container, forKey: .outputTokens)
    self.totalTokens = try Self.count(in: container, forKey: .totalTokens)
  }

  private static func count(
    in container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Int? {
    guard let value = try container.decodeIfPresent(Int.self, forKey: key) else {
      return nil
    }
    guard value >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "a token count cannot be negative"
      )
    }
    return value
  }

  /// An absent total is the checked sum of the parts. Checked rather than saturated: a total that
  /// overflows is not a very large turn, it is a broken one.
  func toChatUsage() throws -> ChatUsage {
    let input = inputTokens ?? 0
    let output = outputTokens ?? 0
    guard let total = totalTokens ?? Self.sum(input, output) else {
      throw ProviderError.terminal(
        status: nil,
        message: "the ChatGPT reply reported a usage total that is not a count"
      )
    }
    return ChatUsage(promptTokens: input, completionTokens: output, totalTokens: total)
  }

  static func sum(_ lhs: Int, _ rhs: Int) -> Int? {
    let (total, overflowed) = lhs.addingReportingOverflow(rhs)
    return overflowed ? nil : total
  }
}

// MARK: - Wire Translation

extension ChatGPTStreamItem {
  fileprivate init(_ item: ChatGPTWireItem) {
    self.type = ChatGPTStreamItemType(item.type)
    self.role = item.role
    self.status = item.status
    self.phase = ChatGPTMessagePhase(item.phase)
    self.callID = item.callID
    self.name = item.name
    self.arguments = item.arguments
    self.outputText =
      item.content?.compactMap { part in
        guard part.type == ChatGPTWireItemContent.outputText else {
          return nil
        }
        return part.text
      } ?? []
    self.encryptedContent = item.encryptedContent
    self.summary = Self.summary(item.summary)
  }

  // swiftlint:disable discouraged_optional_collection
  /// The reasoning summary as text. An omitted array is "the model summarized nothing", not damage,
  /// and a part this build cannot read is skipped rather than allowed to cost the turn — a summary
  /// is continuity material the answer does not depend on.
  private static func summary(_ parts: [JSONValue]?) -> [String] {
    // swiftlint:enable discouraged_optional_collection
    guard let parts else {
      return []
    }
    return parts.compactMap { part in
      guard case .object(let fields) = part, case .string(let text)? = fields["text"] else {
        return nil
      }
      return text
    }
  }
}

extension ChatGPTStreamItemType {
  fileprivate init(_ wire: String) {
    switch wire {
    case "message":
      self = .message
    case "reasoning":
      self = .reasoning
    case "function_call":
      self = .functionCall
    default:
      self = .other(wire)
    }
  }
}

extension ChatGPTMessagePhase {
  static let finalWireName = "final"
  static let finalAnswerWireName = "final_answer"
  static let commentaryWireName = "commentary"
  static let analysisWireName = "analysis"

  fileprivate init(_ wire: String?) {
    switch wire {
    case .none:
      self = .unspecified
    case Self.finalWireName:
      self = .final
    case Self.finalAnswerWireName:
      self = .finalAnswer
    case Self.commentaryWireName:
      self = .commentary
    case Self.analysisWireName:
      self = .analysis
    case .some(let other):
      self = .other(other)
    }
  }

  /// How the phase is written back into replay state, so a replayed item reads as the turn the
  /// backend produced rather than as this build's opinion of it.
  var wireName: String? {
    switch self {
    case .unspecified:
      return nil
    case .final:
      return Self.finalWireName
    case .finalAnswer:
      return Self.finalAnswerWireName
    case .commentary:
      return Self.commentaryWireName
    case .analysis:
      return Self.analysisWireName
    case .other(let name):
      return name
    }
  }
}

extension ChatGPTRemoteFailure {
  fileprivate init(_ error: ChatGPTWireError?) {
    self.code = error?.code
    self.message = error?.message
  }
}

extension ChatGPTResponsesTerminal {
  /// Whether an incomplete response simply ran out of room to answer in — a short answer rather than
  /// a failure.
  var isOutputTokenLimited: Bool {
    incompleteReason == ChatGPTWireIncompleteDetails.outputTokenLimit
  }
}
