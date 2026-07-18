import ClawCore
import Foundation
import Testing

@testable import ClawLLM

private typealias Support = ChatGPTProviderTestSupport

/// Every bound the route reads a stream under, exercised exactly at its cap and one byte, event, or
/// item over it. The pairs matter more than the values: a cap tested only from the failing side
/// passes just as well when the guard rejects everything.
@Suite struct ChatGPTResponsesBoundsTests {
  // MARK: - Event Bytes

  @Test func anEventOfExactlyTheEventCapIsParsed() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    let event = Self.paddedEvent(totalBytes: ChatGPTResponsesBounds.maximumEventBytes)

    // when
    let events = try parser.push(Data((event + "\n\n").utf8))

    // then
    #expect(events.count == 1)
  }

  @Test func anEventOneByteOverTheEventCapIsRejected() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    let event = Self.paddedEvent(totalBytes: ChatGPTResponsesBounds.maximumEventBytes + 1)

    // then
    #expect(throws: ProviderError.self) {
      try parser.push(Data((event + "\n\n").utf8))
    }
  }

  /// An event that has not been delimited yet is still bounded, so a server can neither stall a
  /// stream nor grow the buffer by simply never ending its event.
  @Test func anUndelimitedEventOverTheEventCapIsRejectedBeforeItEnds() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    let partial = Self.paddedEvent(totalBytes: ChatGPTResponsesBounds.maximumEventBytes + 1)

    // then
    #expect(throws: ProviderError.self) {
      try parser.push(Data(partial.utf8))
    }
  }

  // MARK: - Buffer Bytes

  /// The one-over case is well-framed data the parser would happily have drained. It is refused
  /// anyway, which is what proves the raw buffer is bounded *before* the delimiter search rather
  /// than after it.
  @Test func aPushOfExactlyTheBufferCapIsParsed() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.framedFiller(totalBytes: ChatGPTResponsesBounds.maximumBufferedBytes)

    // when
    let events = try parser.push(Data(stream.utf8))

    // then
    #expect(events.isEmpty == false)
  }

  @Test func aPushOneByteOverTheBufferCapIsRejectedEvenThoughItIsWellFramed() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.framedFiller(totalBytes: ChatGPTResponsesBounds.maximumBufferedBytes + 1)

    // then
    #expect(throws: ProviderError.self) {
      try parser.push(Data(stream.utf8))
    }
  }

  // MARK: - Data Event Count

  @Test func exactlyTheDataEventCapIsParsed() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // when
    let count = try Self.pushUnknownEvents(
      ChatGPTResponsesBounds.maximumDataEvents,
      through: &parser
    )

    // then
    #expect(count == 0)
    #expect(parser.hasSeenDataFieldByte)
  }

  @Test func oneDataEventOverTheCapIsRejected() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // then
    #expect(throws: ProviderError.self) {
      try Self.pushUnknownEvents(ChatGPTResponsesBounds.maximumDataEvents + 1, through: &parser)
    }
  }

  // MARK: - Output Item Count

  @Test func exactlyTheOutputItemCapIsAccumulated() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.messageItems(ChatGPTResponsesBounds.maximumOutputItems)

    // when
    let events = try accumulator.consume(try parser.push(Data(stream.utf8)))

    // then
    #expect(Support.finished(events) != nil)
  }

  @Test func oneOutputItemOverTheCapIsRejected() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.messageItems(ChatGPTResponsesBounds.maximumOutputItems + 1)

    // then
    #expect(throws: ProviderError.self) {
      try accumulator.consume(try parser.push(Data(stream.utf8)))
    }
  }

  // MARK: - Accumulated Output Bytes

  @Test func visibleTextOfExactlyTheAccumulatedOutputCapIsAccepted() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.visibleTextStream(bytes: ChatGPTResponsesBounds.maximumAccumulatedOutputBytes)

    // when
    let events = try Self.deliver(stream, through: &parser, into: &accumulator)
    let response = try #require(Support.finished(events))

    // then
    #expect(response.content.utf8.count == ChatGPTResponsesBounds.maximumAccumulatedOutputBytes)
  }

  @Test func visibleTextOneByteOverTheAccumulatedOutputCapIsRejected() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.visibleTextStream(
      bytes: ChatGPTResponsesBounds.maximumAccumulatedOutputBytes + 1
    )

    // then
    #expect(throws: ProviderError.self) {
      try Self.deliver(stream, through: &parser, into: &accumulator)
    }
  }

  /// Tool arguments share the visible text's budget, so a stream cannot double the accumulated
  /// output by splitting it between an answer and a call.
  @Test func toolArgumentsShareTheAccumulatedOutputBudgetWithVisibleText() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let half = ChatGPTResponsesBounds.maximumAccumulatedOutputBytes / 2
    let stream =
      Self.visibleTextEvents(bytes: half + 1) + Self.argumentEvents(bytes: half)
      + Self.event(Self.completed())

    // then
    #expect(throws: ProviderError.self) {
      try Self.deliver(stream, through: &parser, into: &accumulator)
    }
  }

  // MARK: - Non-Visible Delta Retention

  /// A commentary item can never become owner-visible, so its `output_text.delta` events are read by
  /// no path — not the answer, not replay, not the observed-token estimate. Retaining them would let
  /// a stream materialize megabytes of write-only text under the per-event and buffer caps, which
  /// charge only text that can reach the owner. So they are dropped as they arrive: the retained
  /// buffers stay empty across a flood that would weigh megabytes if it were kept.
  @Test func textDeltasForANonVisibleItemAreDroppedNotRetained() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let deltaCount = 8_192
    let fragment = String(repeating: "x", count: 256)
    var stream = Self.addedMessage(index: 0, phase: "commentary")
    for _ in 0..<deltaCount {
      stream += Self.textDeltaEvent(index: 0, text: fragment)
    }

    // when
    _ = try Self.deliver(stream, through: &parser, into: &accumulator)

    // then
    #expect(accumulator.retainedDeltaBytes == 0)
  }

  /// Arguments streamed at a non-function-call item are dispatched by no path, so like non-visible
  /// text they are dropped rather than buffered. The carrier is a visible message item, which proves
  /// the drop turns on the item's type and not on its phase.
  @Test func argumentDeltasForANonFunctionCallItemAreDroppedNotRetained() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let deltaCount = 8_192
    let fragment = String(repeating: "a", count: 256)
    var stream = Self.addedMessage(index: 0, phase: "final")
    for _ in 0..<deltaCount {
      stream += Self.argumentDeltaEvent(index: 0, callID: "call_0", fragment: fragment)
    }

    // when
    _ = try Self.deliver(stream, through: &parser, into: &accumulator)

    // then
    #expect(accumulator.retainedDeltaBytes == 0)
  }

  // MARK: - Response State Bytes

  /// Replay state that fits is kept whole. The payload weighs exactly the cap, which is the boundary
  /// the codec owns and this asserts the accumulator hands it material it can still store.
  @Test func replayStateOfExactlyTheStateCapSurvives() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.reasoningStream(
      encryptedBytes: Self.encryptedBytesForPayload(
        of: ChatGPTProviderStateCodec.maximumStateBytes
      )
    )

    // when
    let events = try accumulator.consume(try parser.push(Data(stream.utf8)))
    let response = try #require(Support.finished(events))
    let state = try #require(response.providerState)

    // then
    #expect(state.payload.count == ChatGPTProviderStateCodec.maximumStateBytes)
    #expect(ChatGPTDurableReplayPayload.decode(state.payload)?.reasoning.count == 1)
  }

  /// State one byte too large costs the session its reasoning continuity and nothing else: the
  /// answer still lands, stamped with the epoch, carrying an empty payload.
  @Test func replayStateOneByteOverTheStateCapDegradesToAnEmptyPayload() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.reasoningStream(
      encryptedBytes: Self.encryptedBytesForPayload(
        of: ChatGPTProviderStateCodec.maximumStateBytes + 1
      )
    )

    // when
    let events = try accumulator.consume(try parser.push(Data(stream.utf8)))
    let response = try #require(Support.finished(events))
    let state = try #require(response.providerState)
    let items = try #require(ChatGPTDurableReplayPayload.decode(state.payload))

    // then
    #expect(response.content == "answer")
    #expect(items.reasoning.isEmpty)
    #expect(items.assistantMessages.isEmpty)
  }

  /// Replay material is bounded as it is retained, not only once it is encoded, so a stream of very
  /// large reasoning items cannot be materialized whole on its way to being discarded. Crossing the
  /// bound costs the session its continuity and never its answer.
  @Test func replayMaterialOverTheStateCapIsDroppedAsItArrivesWithoutFailingTheTurn() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let half = ChatGPTProviderStateCodec.maximumStateBytes / 2
    let stream = Self.reasoningStream(encryptedBytes: half + 1, items: 2)

    // when
    let events = try Self.deliver(stream, through: &parser, into: &accumulator)
    let response = try #require(Support.finished(events))
    let state = try #require(response.providerState)
    let items = try #require(ChatGPTDurableReplayPayload.decode(state.payload))

    // then
    #expect(response.content == "answer")
    #expect(items.reasoning.isEmpty)
  }

  // MARK: - Redaction-Safe Failures

  /// Every bound reports a class and a count. A cap failure that quoted the bytes it refused would
  /// be a leak the cap was there to prevent.
  @Test func aCapFailureReportsOnlyItsClassAndCountsAndNeverTheRefusedBytes() throws {
    // given
    var accumulator = Self.accumulator()
    var parser = ChatGPTResponsesSSEParser()
    let secret = String(repeating: "sk-live-", count: 8)
    let stream = Self.visibleTextStream(
      bytes: ChatGPTResponsesBounds.maximumAccumulatedOutputBytes + 1,
      filler: secret
    )

    // when
    var thrown: (any Error)?
    do {
      _ = try Self.deliver(stream, through: &parser, into: &accumulator)
    } catch {
      thrown = error
    }
    let failure = try #require(thrown as? ProviderError)
    let message = try #require(Support.message(of: failure))

    // then
    #expect(message.contains("sk-live-") == false)
    #expect(message.contains(String(ChatGPTResponsesBounds.maximumAccumulatedOutputBytes)))
  }

  // MARK: - Counter Overflow

  /// The byte budget is summed with saturating arithmetic, so a stream that contrives an overflow is
  /// refused at the cap rather than wrapping into a negative total that would read as headroom.
  @Test func anAccumulatedByteCountThatWouldOverflowSaturatesRatherThanWrapping() {
    // given
    let running = Int.max - 1

    // when
    let total = SaturatingArithmetic.sum(running, 1_024)

    // then
    #expect(total == Int.max)
    #expect(total > ChatGPTResponsesBounds.maximumAccumulatedOutputBytes)
  }
}

// MARK: - Harness

extension ChatGPTResponsesBoundsTests {
  /// Any identity will do: these tests weigh payloads rather than read issuers.
  fileprivate static func accumulator() -> ChatGPTResponsesAccumulator {
    ChatGPTResponsesAccumulator(
      identity: ChatGPTReplayIdentity(profileID: UUID(), wireModel: "gpt-5", epoch: UUID())
    )
  }

  fileprivate static func event(_ payload: String) -> String {
    "data: \(payload)\n\n"
  }

  /// Delivers a stream the way a transport does — in chunks the parser drains as it goes — so that a
  /// test about an accumulation bound cannot trip the raw-buffer bound on its way there.
  fileprivate static func deliver(
    _ stream: String,
    through parser: inout ChatGPTResponsesSSEParser,
    into accumulator: inout ChatGPTResponsesAccumulator
  ) throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    let data = Data(stream.utf8)
    let chunkBytes = 256 * 1024
    for start in stride(from: 0, to: data.count, by: chunkBytes) {
      let chunk = Data(
        data[data.startIndex + start..<min(data.startIndex + start + chunkBytes, data.endIndex)]
      )
      events += try accumulator.consume(try parser.push(chunk))
    }
    return events
  }

  fileprivate static func completed() -> String {
    #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","output":null}}"#
  }
}

// MARK: - Byte-Exact Fixtures

extension ChatGPTResponsesBoundsTests {
  /// A recognized event body padded to weigh exactly `totalBytes`, so a byte bound can be named
  /// rather than approached. The padding is ASCII that JSON never escapes, and the type is a known
  /// one so that reaching the parser's output is what proves the event was accepted.
  fileprivate static func paddedEvent(totalBytes: Int) -> String {
    let prefix = #"data: {"type":"response.output_text.delta","output_index":0,"delta":""#
    let suffix = #""}"#
    let padding = totalBytes - prefix.utf8.count - suffix.utf8.count
    return prefix + String(repeating: "a", count: padding) + suffix
  }

  /// Well-framed events weighing exactly `totalBytes` in total, delimiters included. The last event
  /// absorbs whatever the whole units could not divide, so the total is exact rather than rounded.
  /// Units weigh ~1 MiB — half the event cap — so a buffer-cap's worth of filler is a handful of
  /// large events rather than tens of thousands of tiny ones, each of which would pay its own
  /// framing and JSON decode.
  fileprivate static func framedFiller(totalBytes: Int) -> String {
    let unitBytes = 1024 * 1024
    let unit = paddedEvent(totalBytes: unitBytes - 2) + "\n\n"
    let units = max(0, totalBytes / unitBytes - 2)
    let last = totalBytes - units * unitBytes
    return String(repeating: unit, count: units) + paddedEvent(totalBytes: last - 2) + "\n\n"
  }

  @discardableResult
  fileprivate static func pushUnknownEvents(
    _ count: Int,
    through parser: inout ChatGPTResponsesSSEParser
  ) throws -> Int {
    // Pushed in batches so the raw buffer stays far below its own cap and this test can only ever
    // fail on the event count it is about. The payload is the cheapest thing the counter still
    // charges: a data event whose type the route does not model — the cap counts data events.
    var emitted = 0
    let batchSize = 4_096
    for start in stride(from: 0, to: count, by: batchSize) {
      let batch = String(
        repeating: event(#"{"type":"u"}"#),
        count: min(batchSize, count - start)
      )
      emitted += try parser.push(Data(batch.utf8)).count
    }
    return emitted
  }

  /// A message item added but not yet done, at the given phase. The carrier for a delta flood whose
  /// item never resolves, so the accumulator's retained buffers are what the test weighs.
  fileprivate static func addedMessage(index: Int, phase: String) -> String {
    event(
      #"{"type":"response.output_item.added","output_index":\#(index),"#
        + #""item":{"id":"msg_\#(index)","type":"message","role":"assistant","#
        + #""status":"in_progress","phase":"\#(phase)","content":[]}}"#
    )
  }

  fileprivate static func textDeltaEvent(index: Int, text: String) -> String {
    event(
      #"{"type":"response.output_text.delta","output_index":\#(index),"#
        + #""item_id":"msg_\#(index)","delta":"\#(text)"}"#
    )
  }

  fileprivate static func argumentDeltaEvent(
    index: Int,
    callID: String,
    fragment: String
  ) -> String {
    event(
      #"{"type":"response.function_call_arguments.delta","output_index":\#(index),"#
        + #""call_id":"\#(callID)","delta":"\#(fragment)"}"#
    )
  }

  /// `count` distinct commentary items, each added and done, followed by a successful terminal.
  /// Commentary keeps the visible-text budget out of an item-count test.
  fileprivate static func messageItems(_ count: Int) -> String {
    var stream = ""
    for index in 0..<count {
      stream +=
        event(
          #"{"type":"response.output_item.added","output_index":\#(index),"#
            + #""item":{"id":"msg_\#(index)","type":"message","role":"assistant","#
            + #""status":"in_progress","phase":"commentary","content":[]}}"#
        )
        + event(
          #"{"type":"response.output_item.done","output_index":\#(index),"#
            + #""item":{"id":"msg_\#(index)","type":"message","role":"assistant","#
            + #""status":"completed","phase":"commentary","#
            + #""content":[{"type":"output_text","text":"x"}]}}"#
        )
    }
    return stream + event(completed())
  }

  /// Visible text of exactly `bytes`, delivered as done items so the accumulated budget counts the
  /// authoritative text rather than a delta assembly. Split across items to stay under the event
  /// cap.
  fileprivate static func visibleTextEvents(bytes: Int, filler: String = "a") -> String {
    let chunkBytes = 512 * 1024
    var stream = ""
    var written = 0
    var index = 0
    while written < bytes {
      let width = min(chunkBytes, bytes - written)
      let text = String(
        String(repeating: filler, count: width / filler.utf8.count + 1).prefix(width)
      )
      stream +=
        event(
          #"{"type":"response.output_item.added","output_index":\#(index),"#
            + #""item":{"id":"msg_\#(index)","type":"message","role":"assistant","#
            + #""status":"in_progress","phase":"final","content":[]}}"#
        )
        + event(
          #"{"type":"response.output_item.done","output_index":\#(index),"#
            + #""item":{"id":"msg_\#(index)","type":"message","role":"assistant","#
            + #""status":"completed","phase":"final","#
            + #""content":[{"type":"output_text","text":"\#(text)"}]}}"#
        )
      written += width
      index += 1
    }
    return stream
  }

  fileprivate static func visibleTextStream(bytes: Int, filler: String = "a") -> String {
    visibleTextEvents(bytes: bytes, filler: filler) + event(completed())
  }

  /// Tool arguments of exactly `bytes`, spread over calls that each stay under the event cap.
  fileprivate static func argumentEvents(bytes: Int) -> String {
    let chunkBytes = 512 * 1024
    var stream = ""
    var written = 0
    var index = 1_000
    while written < bytes {
      let width = min(chunkBytes, bytes - written)
      let item =
        #"{"id":"fc_\#(index)","type":"function_call","call_id":"call_\#(index)","#
        + #""name":"clock","arguments":"\#(String(repeating: "a", count: width))"}"#
      stream +=
        event(#"{"type":"response.output_item.added","output_index":\#(index),"item":\#(item)}"#)
        + event(#"{"type":"response.output_item.done","output_index":\#(index),"item":\#(item)}"#)
      written += width
      index += 1
    }
    return stream
  }

  /// `items` reasoning items whose encrypted content each weighs `encryptedBytes`, plus a short
  /// visible answer so the turn has something to succeed with.
  fileprivate static func reasoningStream(encryptedBytes: Int, items: Int = 1) -> String {
    var stream = ""
    for index in 0..<items {
      let item =
        #"{"id":"rs_\#(index)","type":"reasoning","#
        + #""encrypted_content":"\#(String(repeating: "a", count: encryptedBytes))"}"#
      stream +=
        event(
          #"{"type":"response.output_item.added","output_index":\#(index),"item":\#(item)}"#
        )
        + event(#"{"type":"response.output_item.done","output_index":\#(index),"item":\#(item)}"#)
    }
    // The answer follows the reasoning items rather than sharing an index with one.
    return stream
      + event(
        #"{"type":"response.output_item.added","output_index":\#(items),"#
          + #""item":{"id":"msg_1","type":"message","role":"assistant","#
          + #""status":"in_progress","phase":"final","content":[]}}"#
      )
      + event(
        #"{"type":"response.output_item.done","output_index":\#(items),"#
          + #""item":{"id":"msg_1","type":"message","role":"assistant","#
          + #""status":"completed","phase":"final","#
          + #""content":[{"type":"output_text","text":"answer"}]}}"#
      )
      + event(completed())
  }

  /// How much encrypted content makes the canonical payload weigh exactly `payloadBytes`. Derived
  /// from an empty encoding rather than guessed, so the state boundary is named exactly.
  fileprivate static func encryptedBytesForPayload(of payloadBytes: Int) -> Int {
    let empty = ChatGPTReplayItems(
      reasoning: [ChatGPTReasoningItem(encryptedContent: "")],
      assistantMessages: [
        ChatGPTAssistantMessageItem(status: "completed", phase: "final", outputText: ["answer"])
      ]
    )
    let baseline = CanonicalJSON.encode(ChatGPTDurableReplayPayload(empty))?.utf8.count ?? 0
    return payloadBytes - baseline
  }
}
