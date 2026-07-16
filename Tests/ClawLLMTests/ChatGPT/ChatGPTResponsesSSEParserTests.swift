import ClawCore
import Foundation
import Testing

@testable import ClawLLM

@Suite struct ChatGPTResponsesSSEParserTests {
  // MARK: - Reconstruction

  /// The whole reply for the recorded basic stream, whose terminal carries `"output":null`. Every
  /// field is a literal: an expectation re-derived from the accumulator would move with it and pin
  /// nothing. If reconstruction ever read the terminal's own `output`, `content` would be empty.
  @Test func nullOutputTerminalStillReconstructsTheWholeReplyFromItemEvents() throws {
    // given
    let stream = try Self.fixture("basic-response")

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas == ["Hello", ", wor"])
    #expect(run.response.content == "Hello, world!")
    #expect(run.response.finishReason == "stop")
    #expect(run.response.usage == ChatUsage(promptTokens: 11, completionTokens: 5, totalTokens: 16))
    #expect(run.response.toolCalls.isEmpty)
  }

  /// A byte-at-a-time delivery cuts multi-byte scalars, field lines, and event delimiters apart. The
  /// reply is identical to the whole-chunk delivery, which is what proves the framing buffers rather
  /// than decoding what it happens to hold.
  @Test func splitUTF8ScalarsAndFragmentedFieldLinesReconstructIdentically() throws {
    // given
    let stream = Self.messageStream(text: "héllo → 🌍 done")

    // when
    let whole = try Self.consume(stream)
    let dribbled = try Self.consume(stream, chunkSize: 1)

    // then
    #expect(dribbled.response.content == "héllo → 🌍 done")
    #expect(dribbled.response.content == whole.response.content)
    #expect(dribbled.deltas == whole.deltas)
  }

  @Test func crlfFramingCommentsAndSeveralEventsInOneChunkAreParsed() throws {
    // given
    let stream =
      ": keep-alive\r\n\r\n"
      + Self.event(Self.addedMessage(index: 0, phase: "final"), separator: "\r\n")
      + Self.event(Self.textDelta(index: 0, text: "one"), separator: "\r\n")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "one"), separator: "\r\n")
      + Self.event(Self.completed(), separator: "\r\n")

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas == ["one"])
    #expect(run.response.content == "one")
  }

  /// Unknown event types and unknown fields are data the route does not model. They are ignored
  /// rather than rejected, and the known events around them still reconstruct.
  @Test func unknownEventsAreIgnoredWithoutFailingTheStream() throws {
    // given
    let stream =
      Self.event(#"{"type":"response.reasoning_summary_part.added","output_index":0}"#)
      + Self.event(#"{"type":"something.we.have.never.seen","payload":{"nested":[1,2]}}"#)
      + Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.textDelta(index: 0, text: "still here"))
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "still here"))
      + Self.event(Self.completed())

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas == ["still here"])
    #expect(run.response.content == "still here")
  }

  // MARK: - Tool Calls

  /// `response.done` is the observed alias for a successful terminal, and the arguments `.done`
  /// event reconciles a delta assembly that only ever reached `{"zone":"UT`.
  @Test func toolStreamReconcilesArgumentsAndFinishesWithToolCalls() throws {
    // given
    let stream = try Self.fixture("tool-response")

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas.isEmpty)
    #expect(run.response.content.isEmpty)
    #expect(
      run.response.toolCalls == [
        ToolCall(id: "call_abc", name: "clock", argumentsJSON: #"{"zone":"UTC"}"#)
      ]
    )
    #expect(run.response.finishReason == "tool_calls")
    #expect(run.response.usage == ChatUsage(promptTokens: 20, completionTokens: 9, totalTokens: 29))
  }

  // MARK: - Message Phases

  /// Commentary and analysis are the model's working notes. They never reach a delta or the final
  /// answer; the paired positive is the `final_answer` item in the same stream, which does both.
  @Test func commentaryAndAnalysisNeverReachADeltaOrTheFinalAnswer() throws {
    // given
    let stream = try Self.fixture("reasoning-response")

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas == ["The answer."])
    #expect(run.response.content == "The answer.")
    #expect(run.response.content.contains("weighing the options") == false)
    #expect(run.response.content.contains("scratch work") == false)
  }

  /// The same commentary the owner never sees is kept for replay, phase and all, so the next request
  /// can hand the backend back the turn it actually produced.
  @Test func commentaryAndAnalysisSurviveOnlyInReplayState() throws {
    // given
    let stream = try Self.fixture("reasoning-response")

    // when
    let run = try Self.consume(stream)
    let items = try #require(Self.replayItems(run.response))

    // then
    #expect(
      items.assistantMessages == [
        ChatGPTAssistantMessageItem(
          role: "assistant",
          status: "completed",
          phase: "commentary",
          outputText: ["weighing the options"]
        ),
        ChatGPTAssistantMessageItem(
          role: "assistant",
          status: "completed",
          phase: "final_answer",
          outputText: ["The answer."]
        ),
      ]
    )
  }

  /// A phase the route has never heard of is not known to be owner-visible, so it is treated as
  /// working notes rather than published on the assumption that a new name is safe.
  @Test func anUnrecognizedPhaseIsNotPublished() throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "draft")
      + Self.event(Self.textDelta(index: 0, text: "half-formed"))
      + Self.event(Self.doneMessage(index: 0, phase: "draft", text: "half-formed"))
      + Self.event(Self.completed())

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas.isEmpty)
    #expect(run.response.content.isEmpty)
  }

  @Test func anAbsentPhaseIsPublished() throws {
    // given
    let stream =
      Self.event(
        #"{"type":"response.output_item.added","output_index":0,"#
          + #""item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#
      )
      + Self.event(Self.textDelta(index: 0, text: "plain"))
      + Self.event(
        #"{"type":"response.output_item.done","output_index":0,"#
          + #""item":{"id":"msg_1","type":"message","role":"assistant","status":"completed","#
          + #""content":[{"type":"output_text","text":"plain"}]}}"#
      )
      + Self.event(Self.completed())

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas == ["plain"])
    #expect(run.response.content == "plain")
  }

  // MARK: - Reasoning

  /// An omitted summary is "none", not damage, and a supplied one keeps its text. Neither reaches
  /// the owner's answer.
  @Test func reasoningNormalizesAnOmittedSummaryToAnEmptyArray() throws {
    // given
    let stream = try Self.fixture("reasoning-response")

    // when
    let run = try Self.consume(stream)
    let items = try #require(Self.replayItems(run.response))

    // then
    #expect(
      items.reasoning == [
        ChatGPTReasoningItem(encryptedContent: "ENC-ONE", summary: []),
        ChatGPTReasoningItem(encryptedContent: "ENC-TWO", summary: ["Checked the clock."]),
      ]
    )
  }

  /// Reasoning that never resolved is continuity material the turn does not depend on, so it is
  /// dropped and the answer still lands.
  @Test func unresolvedReasoningIsOmittedFromReplayStateWithoutFailingTheTurn() throws {
    // given
    let stream =
      Self.event(
        #"{"type":"response.output_item.added","output_index":0,"#
          + #""item":{"id":"rs_1","type":"reasoning","encrypted_content":"ENC"}}"#
      )
      + Self.addedMessageEvent(index: 1, phase: "final")
      + Self.event(Self.textDelta(index: 1, text: "answer"))
      + Self.event(Self.doneMessage(index: 1, phase: "final", text: "answer"))
      + Self.event(Self.completed())

    // when
    let run = try Self.consume(stream)
    let items = try #require(Self.replayItems(run.response))

    // then
    #expect(run.response.content == "answer")
    #expect(items.reasoning.isEmpty)
  }

  // MARK: - Synthesis

  /// The backend truncated the message item away, so the visible deltas are all there is. Only the
  /// visible text is synthesized — the commentary deltas in the same stream stay out of it.
  @Test func aSuccessfulTerminalSynthesizesOnlyVisibleTextWhenTheDoneMessageIsAbsent() throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "commentary")
      + Self.event(Self.textDelta(index: 0, text: "notes to self"))
      + Self.addedMessageEvent(index: 1, phase: "final")
      + Self.event(Self.textDelta(index: 1, text: "half an "))
      + Self.event(Self.textDelta(index: 1, text: "answer"))
      + Self.event(Self.completed())

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.deltas == ["half an ", "answer"])
    #expect(run.response.content == "half an answer")
  }

  // MARK: - Retry Boundary

  /// Framing comments are not content: a stream that has only ever sent keep-alives can still be
  /// re-issued. The paired positive below proves the flag is not simply stuck at false.
  @Test func framingCommentsAloneDoNotCrossTheRetryBoundary() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // when
    _ = try parser.push(Data(": keep-alive\n\n: still here\n\nevent: response.created\n\n".utf8))

    // then
    #expect(parser.hasSeenDataFieldByte == false)
  }

  @Test func aDataFieldCrossesTheRetryBoundary() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // when
    _ = try parser.push(Data(": keep-alive\n\n".utf8))
    let beforeData = parser.hasSeenDataFieldByte
    _ = try parser.push(Data("data: {\"type\":\"response.created\"}\n\n".utf8))

    // then
    #expect(beforeData == false)
    #expect(parser.hasSeenDataFieldByte)
  }

  /// The boundary closes on the field's first byte, before the event delimiter and before any JSON
  /// decode. This event never completes and never decodes, and it still cannot be replayed.
  @Test func aFragmentedDataEventCrossesTheBoundaryBeforeTheDelimiterOrDecode() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // when
    let events = try parser.push(Data("event: response.completed\ndata: {\"ty".utf8))

    // then
    #expect(events.isEmpty)
    #expect(parser.hasSeenDataFieldByte)
  }

  @Test func anUnknownDataEventCrossesTheBoundary() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // when
    let events = try parser.push(Data("event: nonsense\ndata: {\"type\":\"nonsense\"}\n\n".utf8))

    // then
    #expect(events.isEmpty)
    #expect(parser.hasSeenDataFieldByte)
  }

  /// A `data:` field split across chunks mid-name still closes the boundary: the scan is stateful,
  /// so the field is recognized however the transport happened to cut it.
  @Test func aDataFieldNameSplitAcrossChunksCrossesTheBoundary() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // when
    _ = try parser.push(Data("da".utf8))
    let beforeRest = parser.hasSeenDataFieldByte
    _ = try parser.push(Data("ta: {".utf8))

    // then
    #expect(beforeRest == false)
    #expect(parser.hasSeenDataFieldByte)
  }

  /// A comment that merely quotes the field name is still a comment.
  @Test func aCommentMentioningTheFieldNameDoesNotCrossTheBoundary() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()

    // when
    _ = try parser.push(Data(": data: not really\n\n".utf8))

    // then
    #expect(parser.hasSeenDataFieldByte == false)
  }

  // MARK: - Terminal Selection

  /// An output-token limit is a truncated answer, not a failure: the owner keeps the text and the
  /// runtime learns why it stopped.
  @Test func anIncompleteOutputTokenLimitFinishesWithLength() throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.textDelta(index: 0, text: "as far as I got"))
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "as far as I got"))
      + Self.event(
        #"{"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","#
          + #""incomplete_details":{"reason":"max_output_tokens"}}}"#
      )

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.response.content == "as far as I got")
    #expect(run.response.finishReason == "length")
  }

  /// Every other terminal state the route can name is a failure rather than a short answer.
  @Test(
    arguments: [
      #"{"type":"response.incomplete","response":{"id":"r","status":"incomplete","#
        + #""incomplete_details":{"reason":"content_filter"}}}"#,
      #"{"type":"response.incomplete","response":{"id":"r","status":"incomplete"}}"#,
      #"{"type":"response.failed","response":{"id":"r","status":"failed","#
        + #""error":{"code":"server_error","message":"boom"}}}"#,
      #"{"type":"response.completed","response":{"id":"r","status":"cancelled"}}"#,
      #"{"type":"error","error":{"code":"rate_limit","message":"slow down"}}"#,
    ]
  )
  func nonSuccessfulTerminalsBecomeProviderFailures(terminal: String) throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.textDelta(index: 0, text: "some text"))
      + Self.event(terminal)

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  /// The nested status is the meaning; the event name is only the fallback. A `response.completed`
  /// carrying a failed status is a failure, not a success.
  @Test func theNestedStatusOutranksTheEventName() throws {
    // given
    let succeeding =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "fine"))
      + Self.event(#"{"type":"response.failed","response":{"id":"r","status":"completed"}}"#)
    let failing =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "fine"))
      + Self.event(#"{"type":"response.completed","response":{"id":"r","status":"failed"}}"#)

    // when
    let run = try Self.consume(succeeding)

    // then
    #expect(run.response.content == "fine")
    #expect(throws: ProviderError.self) {
      try Self.consume(failing)
    }
  }

  /// With no status to read, the event name decides — which is what keeps a backend that stopped
  /// sending one working.
  @Test func theEventNameDecidesWhenTheNestedStatusIsAbsent() throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "named"))
      + Self.event(#"{"type":"response.completed","response":{"id":"r"}}"#)

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.response.content == "named")
    #expect(run.response.finishReason == "stop")
  }

  /// The first terminal is final and is answered from the batch in hand. Nothing after it — in this
  /// push or a later one — can change or reopen the outcome.
  @Test func theFirstTerminalWinsWithoutWaitingForALaterEventOrEOF() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    var accumulator = Self.accumulator()
    // The trailing delta is decoded in the *same* batch as the terminal, so a parser that kept
    // applying the batch past its outcome would publish it.
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "first"))
      + Self.event(Self.completed())
      + Self.event(Self.textDelta(index: 0, text: "same batch"))

    // when
    let events = try accumulator.consume(try parser.push(Data(stream.utf8)))
    let afterwards = try accumulator.consume(
      try parser.push(Data(Self.event(Self.textDelta(index: 0, text: "later batch")).utf8))
    )

    // then
    #expect(events.contains(.delta("same batch")) == false)
    #expect(afterwards.isEmpty)
    #expect(try accumulator.finish() == nil)
    #expect(Self.finished(events)?.content == "first")
  }

  /// Two terminals that disagree, already decoded in one delivered batch, are a stream the parser
  /// cannot honestly answer for — so it refuses rather than picking one. The paired positive is the
  /// `response.done` alias restating the same terminal, which is not a conflict.
  @Test func aConflictingSecondTerminalInTheSameBatchIsRejected() throws {
    // given
    let conflicting =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "text"))
      + Self.event(Self.completed(id: "resp_1"))
      + Self.event(#"{"type":"response.failed","response":{"id":"resp_1","status":"failed"}}"#)

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(conflicting)
    }
  }

  @Test func theDoneAliasRestatingTheSameTerminalIsNotAConflict() throws {
    // given
    let repeated =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "text"))
      + Self.event(Self.completed(id: "resp_1"))
      + Self.event(#"{"type":"response.done","response":{"id":"resp_1","status":"completed"}}"#)

    // when
    let run = try Self.consume(repeated)

    // then
    #expect(run.response.content == "text")
  }

  /// A conflicting terminal that arrives in a *later* batch is not consulted: the outcome was
  /// already decided and the parser does not wait for the wire to finish having opinions.
  @Test func aConflictingTerminalInALaterBatchIsIgnoredRatherThanRejected() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    var accumulator = Self.accumulator()
    let decided =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "decided"))
      + Self.event(Self.completed(id: "resp_1"))

    // when
    let events = try accumulator.consume(try parser.push(Data(decided.utf8)))
    let later = try accumulator.consume(
      try parser.push(
        Data(
          Self.event(#"{"type":"response.failed","response":{"id":"resp_2","status":"failed"}}"#)
            .utf8
        )
      )
    )

    // then
    #expect(Self.finished(events)?.content == "decided")
    #expect(later.isEmpty)
  }

  // MARK: - EOF

  /// A stream that simply ended is ambiguous: the model may well have generated the answer we never
  /// received. Reporting an empty success here would hand the owner a blank reply and hide the cost.
  @Test func aTerminalFreeEOFIsAnAmbiguousFailureRatherThanAnEmptySuccess() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    var accumulator = Self.accumulator()
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.textDelta(index: 0, text: "an answer that never landed"))
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "an answer that never landed"))

    // when
    _ = try accumulator.consume(try parser.push(Data(stream.utf8)))

    // then
    #expect(throws: ProviderError.self) {
      try accumulator.finish()
    }
    #expect(accumulator.observedCompletionTokens > 0)
  }

  @Test func aTerminalFreeEOFWithNoEventsAtAllIsStillAFailure() throws {
    // given
    var accumulator = Self.accumulator()

    // then
    #expect(throws: ProviderError.self) {
      try accumulator.finish()
    }
    #expect(accumulator.observedCompletionTokens == 0)
  }

  // MARK: - Usage

  /// A count that is negative, fractional, or too large to be a count at all is damage, not
  /// accounting. The paired positive is the basic fixture's usage, which maps through intact.
  @Test(
    arguments: [
      #"{"input_tokens":-1,"output_tokens":5,"total_tokens":4}"#,
      #"{"input_tokens":11,"output_tokens":-5,"total_tokens":6}"#,
      #"{"input_tokens":1.5,"output_tokens":5,"total_tokens":7}"#,
      #"{"input_tokens":11,"output_tokens":99999999999999999999999,"total_tokens":5}"#,
      #"{"input_tokens":"eleven","output_tokens":5,"total_tokens":16}"#,
    ]
  )
  func aDamagedUsageCountMakesTheResponseMalformed(usage: String) throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "text"))
      + Self.event(
        #"{"type":"response.completed","response":{"id":"r","status":"completed","usage":\#(usage)}}"#
      )

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  /// An absent total is the checked sum of the parts rather than a zero that would understate the
  /// turn.
  @Test func anAbsentTotalIsTheSumOfInputAndOutput() throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "text"))
      + Self.event(
        #"{"type":"response.completed","response":{"id":"r","status":"completed","#
          + #""usage":{"input_tokens":7,"output_tokens":3}}}"#
      )

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.response.usage == ChatUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10))
  }

  /// Usage the route never sent is absent, not zero: `ChatUsage.zero` is a genuine measurement and
  /// would let a missing accounting read as a free turn.
  @Test func anAbsentUsageObjectLeavesTheResponseUsageNil() throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "text"))
      + Self.event(#"{"type":"response.completed","response":{"id":"r","status":"completed"}}"#)

    // when
    let run = try Self.consume(stream)

    // then
    #expect(run.response.usage == nil)
  }

  @Test func aMalformedNestedResponseObjectIsRejected() throws {
    // given
    let stream =
      Self.addedMessageEvent(index: 0, phase: "final")
      + Self.event(Self.doneMessage(index: 0, phase: "final", text: "text"))
      + Self.event(#"{"type":"response.completed","response":{"id":"r","status":7}}"#)

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  // MARK: - Malformed Items

  /// A call whose identity changes between events cannot be paired with its result, and inventing a
  /// winner would attach the output to someone else's call.
  @Test func aCallIDThatChangesBetweenEventsIsRejected() throws {
    // given
    let stream =
      Self.event(
        #"{"type":"response.output_item.added","output_index":0,"#
          + #""item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"clock"}}"#
      )
      + Self.event(
        #"{"type":"response.output_item.done","output_index":0,"#
          + #""item":{"id":"fc_1","type":"function_call","call_id":"call_b","#
          + #""name":"clock","arguments":"{}"}}"#
      )
      + Self.event(Self.completed())

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  /// Two items claiming one call ID would give the dispatcher two calls it cannot tell apart, and a
  /// tool result names only the ID.
  @Test func twoOutputItemsSharingOneCallIDAreRejected() throws {
    // given
    let stream =
      Self.functionCallEvents(index: 0, callID: "call_same", name: "clock")
      + Self.functionCallEvents(index: 1, callID: "call_same", name: "clock")
      + Self.event(Self.completed())

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  /// A call with no name or no ID is not dispatchable. The paired positive is the tool fixture,
  /// where both are present and the call survives.
  @Test(
    arguments: [
      #"{"id":"fc_1","type":"function_call","call_id":"call_a","arguments":"{}"}"#,
      #"{"id":"fc_1","type":"function_call","call_id":"","name":"clock","arguments":"{}"}"#,
      #"{"id":"fc_1","type":"function_call","name":"clock","arguments":"{}"}"#,
      #"{"id":"fc_1","type":"function_call","call_id":"call_a","name":"","arguments":"{}"}"#,
    ]
  )
  func aFunctionCallMissingItsNameOrCallIDIsRejected(item: String) throws {
    // given
    let stream =
      Self.event(#"{"type":"response.output_item.added","output_index":0,"item":\#(item)}"#)
      + Self.event(#"{"type":"response.output_item.done","output_index":0,"item":\#(item)}"#)
      + Self.event(Self.completed())

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  /// A function call the stream never resolved would be dispatched from truncated arguments. Unlike
  /// reasoning, it cannot be quietly dropped: the model asked for it.
  @Test func anUnresolvedFunctionCallIsMalformed() throws {
    // given
    let stream =
      Self.event(
        #"{"type":"response.output_item.added","output_index":0,"#
          + #""item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"clock"}}"#
      )
      + Self.event(
        #"{"type":"response.function_call_arguments.delta","output_index":0,"#
          + #""item_id":"fc_1","call_id":"call_a","delta":"{\"zo"}"#
      )
      + Self.event(Self.completed())

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  /// Text whose phase was never registered has no filter to pass. Publishing it would mean guessing
  /// that unannounced text is owner-visible, which is exactly the guess the phase filter exists to
  /// refuse.
  @Test func aDeltaForAnUnregisteredOutputItemIsRejected() throws {
    // given
    let stream =
      Self.event(Self.textDelta(index: 3, text: "out of nowhere")) + Self.event(Self.completed())

    // then
    #expect(throws: ProviderError.self) {
      try Self.consume(stream)
    }
  }

  // MARK: - Sanitized Diagnostics

  /// A failure after visible data still has to be reportable. The remote message reaches the owner
  /// stripped of the escape sequences that would repaint their terminal, with its whitespace
  /// collapsed, and the tokens already generated are accounted for.
  @Test func aFailureAfterVisibleDataIsReportedSanitizedWithObservedTokens() throws {
    // given
    var parser = ChatGPTResponsesSSEParser()
    var accumulator = Self.accumulator()
    let stream = try Self.fixture("error-response")

    // when
    var thrown: (any Error)?
    do {
      _ = try accumulator.consume(try parser.push(Data(stream.utf8)))
    } catch {
      thrown = error
    }
    let failure = try #require(thrown as? ProviderError)

    // then
    let message = try #require(Self.message(of: failure))
    #expect(message.contains("upstream exploded retry later"))
    #expect(message.contains("\u{1B}") == false)
    #expect(message.contains("[31m") == false)
    // "Partial visible text" — 20 graphemes through the existing estimator.
    #expect(accumulator.observedCompletionTokens == 7)
  }

  /// The redaction set the provider carries reaches the parser's diagnostics, so a route that echoed
  /// a bearer back cannot launder it through an error message.
  @Test func aRemoteDiagnosticIsRedactedWithTheSuppliedSecrets() throws {
    // given
    var accumulator = Self.accumulator(redacting: ["sk-live-secret"])
    var parser = ChatGPTResponsesSSEParser()
    let stream = Self.event(
      #"{"type":"error","error":{"code":"bad","message":"token sk-live-secret rejected"}}"#
    )

    // when
    var thrown: (any Error)?
    do {
      _ = try accumulator.consume(try parser.push(Data(stream.utf8)))
    } catch {
      thrown = error
    }
    let failure = try #require(thrown as? ProviderError)

    // then
    let message = try #require(Self.message(of: failure))
    #expect(message.contains("sk-live-secret") == false)
    #expect(message.contains(SecretRedactor.replacement))
  }
}

// MARK: - Stream Assembly

extension ChatGPTResponsesSSEParserTests {
  fileprivate struct StreamRun {
    let deltas: [String]
    let response: ChatResponse
  }

  /// Any identity will do: nothing here asserts on the issuer, only on the material stamped with it.
  /// Generating one rather than pinning a literal is what says so.
  fileprivate static func accumulator(
    redacting secrets: [String] = []
  ) -> ChatGPTResponsesAccumulator {
    ChatGPTResponsesAccumulator(
      identity: ChatGPTReplayIdentity(profileID: UUID(), wireModel: "gpt-5", epoch: UUID()),
      redactionValues: secrets
    )
  }

  /// Drives the parser and the accumulator the way the provider will: every chunk the transport
  /// hands over is pushed, framed, and consumed in one batch.
  fileprivate static func consume(_ stream: String, chunkSize: Int? = nil) throws -> StreamRun {
    var parser = ChatGPTResponsesSSEParser()
    var accumulator = accumulator()
    var deltas: [String] = []
    var response: ChatResponse?

    for chunk in chunks(of: Data(stream.utf8), size: chunkSize) {
      for event in try accumulator.consume(try parser.push(chunk)) {
        switch event {
        case .delta(let text):
          deltas.append(text)
        case .finished(let finished):
          response = finished
        }
      }
    }

    guard let response else {
      _ = try accumulator.finish()
      throw ProviderError.terminal(status: nil, message: "the stream produced no terminal")
    }
    return StreamRun(deltas: deltas, response: response)
  }

  fileprivate static func chunks(of data: Data, size: Int?) -> [Data] {
    guard let size, size > 0 else {
      return [data]
    }
    return stride(from: 0, to: data.count, by: size).map { start in
      Data(data[data.startIndex + start..<min(data.startIndex + start + size, data.endIndex)])
    }
  }

  fileprivate static func finished(_ events: [StreamEvent]) -> ChatResponse? {
    events.compactMap { event -> ChatResponse? in
      guard case .finished(let response) = event else {
        return nil
      }
      return response
    }
    .last
  }

  fileprivate static func replayItems(_ response: ChatResponse) -> ChatGPTReplayItems? {
    guard let state = response.providerState else {
      return nil
    }
    return ChatGPTDurableReplayPayload.decode(state.payload)
  }

  fileprivate static func message(of failure: ProviderError) -> String? {
    switch failure {
    case .connectFailed(let message):
      return message
    case .retryable(_, let message), .rejected(_, let message), .terminal(_, let message):
      return message
    case .authenticationRequired, .accessDenied, .quotaLimited, .cleanRejection,
      .invalidProviderState:
      return nil
    }
  }

  fileprivate static func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent("\(name).sse")
    return try String(contentsOf: url, encoding: .utf8)
  }
}

// MARK: - Event Fixtures

extension ChatGPTResponsesSSEParserTests {
  fileprivate static func event(_ payload: String, separator: String = "\n") -> String {
    "data: \(payload)\(separator)\(separator)"
  }

  fileprivate static func addedMessage(index: Int, phase: String) -> String {
    #"{"type":"response.output_item.added","output_index":\#(index),"#
      + #""item":{"id":"msg_\#(index)","type":"message","role":"assistant","#
      + #""status":"in_progress","phase":"\#(phase)","content":[]}}"#
  }

  fileprivate static func addedMessageEvent(index: Int, phase: String) -> String {
    event(addedMessage(index: index, phase: phase))
  }

  fileprivate static func doneMessage(index: Int, phase: String, text: String) -> String {
    #"{"type":"response.output_item.done","output_index":\#(index),"#
      + #""item":{"id":"msg_\#(index)","type":"message","role":"assistant","#
      + #""status":"completed","phase":"\#(phase)","#
      + #""content":[{"type":"output_text","text":"\#(text)"}]}}"#
  }

  fileprivate static func textDelta(index: Int, text: String) -> String {
    #"{"type":"response.output_text.delta","output_index":\#(index),"#
      + #""item_id":"msg_\#(index)","delta":"\#(text)"}"#
  }

  fileprivate static func completed(id: String = "resp_1") -> String {
    #"{"type":"response.completed","response":{"id":"\#(id)","status":"completed","output":null}}"#
  }

  fileprivate static func functionCallEvents(index: Int, callID: String, name: String) -> String {
    let item =
      #"{"id":"fc_\#(index)","type":"function_call","call_id":"\#(callID)","#
      + #""name":"\#(name)","arguments":"{}"}"#
    return event(#"{"type":"response.output_item.added","output_index":\#(index),"item":\#(item)}"#)
      + event(#"{"type":"response.output_item.done","output_index":\#(index),"item":\#(item)}"#)
  }

  /// One visible message whose text is delivered as a single delta and restated by its done item —
  /// the shape most framing tests only need as a carrier.
  fileprivate static func messageStream(text: String) -> String {
    addedMessageEvent(index: 0, phase: "final")
      + event(textDelta(index: 0, text: text))
      + event(doneMessage(index: 0, phase: "final", text: text))
      + event(completed())
  }
}
