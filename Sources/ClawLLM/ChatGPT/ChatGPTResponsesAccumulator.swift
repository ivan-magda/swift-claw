import ClawAuth
import ClawCore
import Foundation

/// Rebuilds one authoritative reply from a Responses stream's item events.
///
/// The terminal event is asked only what the response *ended as* — its status, ID, usage, and error.
/// The answer itself is rebuilt from the items, because the studied backend can send
/// `response.completed.response.output = null` for a stream that produced a perfectly good reply;
/// a reconstruction that trusted the terminal's own output would hand the owner a blank turn.
///
/// It is pure: no transport, no credential, no clock. What it owns is the judgment of which text the
/// owner may see, which terminal is final, and what the turn cost.
struct ChatGPTResponsesAccumulator: Sendable {
  private let codec: ChatGPTProviderStateCodec
  private let identity: ChatGPTReplayIdentity
  private let redactionValues: [String]

  private var items: [Int: OutputItem] = [:]
  private var order: [Int] = []
  private var accumulatedOutputBytes = 0
  private var replayBytes = 0
  private var replayOverflowed = false
  private var isDecided = false

  /// The redaction set is injected because this type has no credential to derive one from: the
  /// values travel with the authorization the provider used, and only the provider knows them.
  init(
    codec: ChatGPTProviderStateCodec = ChatGPTProviderStateCodec(),
    identity: ChatGPTReplayIdentity,
    redactionValues: [String] = []
  ) {
    self.codec = codec
    self.identity = identity
    self.redactionValues = redactionValues
  }

  /// A lower bound on the completion tokens this attempt may already be billed for, derived only
  /// from text that has already passed the accumulated-output cap, through the estimator the rest of
  /// the daemon accounts with. Per item, so each item's rounding adds headroom rather than shaving
  /// it — the same way input estimation sums per message.
  var observedCompletionTokens: Int {
    order.reduce(0) { running, index in
      guard let item = items[index] else {
        return running
      }
      return SaturatingArithmetic.sum(
        running,
        SaturatingArithmetic.sum(
          TokenEstimator.estimateTokens(forText: item.visibleText),
          TokenEstimator.estimateTokens(forText: item.argumentText)
        )
      )
    }
  }

  /// The bytes held in the raw per-item delta buffers, whether or not any of them can reach the
  /// owner. Distinct from the accumulated-output budget, which charges only text the owner may see:
  /// this weighs the buffers themselves, so a memory-bound test can prove deltas for an item no path
  /// will ever read are dropped as they arrive rather than retained under the byte caps.
  var retainedDeltaBytes: Int {
    order.reduce(0) { running, index in
      guard let item = items[index] else {
        return running
      }
      return SaturatingArithmetic.sum(
        running,
        SaturatingArithmetic.sum(item.deltaText.utf8.count, item.argumentDeltas.utf8.count)
      )
    }
  }

  /// Consumes one delivered batch, emitting the deltas the owner may see and, once the stream states
  /// its outcome, the whole reply.
  ///
  /// The first recognized terminal is final. Every event already decoded in this same batch is
  /// checked against it, so a stream that contradicts itself in one delivery is refused rather than
  /// answered from whichever terminal happened to be first. Nothing waits for a later event or for
  /// EOF: the batch in hand is all the evidence there will ever be.
  mutating func consume(_ events: [ChatGPTResponsesEvent]) throws -> [StreamEvent] {
    guard isDecided == false else {
      return []
    }

    var emitted: [StreamEvent] = []
    for (offset, event) in events.enumerated() {
      switch event {
      case .terminal(let terminal):
        try validateNoConflict(with: terminal, after: offset, in: events)
        isDecided = true
        emitted.append(.finished(try response(for: terminal)))
        return emitted
      case .streamError(let failure):
        isDecided = true
        throw self.failure(failure)
      default:
        if let delta = try apply(event) {
          emitted.append(.delta(delta))
        }
      }
    }
    return emitted
  }

  /// The end of the body. A stream that never stated an outcome is ambiguous — the model may well
  /// have generated the answer that never arrived — so this is a failure rather than an empty
  /// success, and the caller accounts for it with `observedCompletionTokens`.
  mutating func finish() throws -> StreamEvent? {
    guard isDecided == false else {
      return nil
    }
    isDecided = true
    throw Self.ambiguousEnd
  }
}

// MARK: - Accumulated Item

/// One output item as it is being assembled. It carries what it currently contributes to the
/// accumulated-output budget so a done item that supersedes a delta assembly can hand those bytes
/// back rather than being charged for the same text twice.
private struct OutputItem {
  let type: ChatGPTStreamItemType
  /// Registered once, at first sighting, and never re-read from a later event. One phase governs
  /// both what was published and what is stored, so a stream cannot contradict a delta the owner has
  /// already been shown.
  let phase: ChatGPTMessagePhase

  var callID: String?
  var deltaText = ""
  var doneText: String?
  var argumentDeltas = ""
  var arguments: String?
  var done: ChatGPTStreamItem?
  var countedBytes = 0

  /// Whether text for this item can ever reach the owner. Phase and type are frozen at first
  /// sighting, so an item that fails this can never later become visible — its text is read nowhere
  /// and is dropped as it arrives rather than buffered.
  var retainsText: Bool {
    type == .message && phase.isOwnerVisible
  }

  /// Whether arguments for this item can ever be dispatched. Type is frozen at first sighting, so an
  /// item that fails this proposes no call — its arguments are read nowhere and are dropped rather
  /// than buffered.
  var retainsArguments: Bool {
    type == .functionCall
  }

  /// The text of this item the owner may see. A done item is the source of truth; the delta assembly
  /// stands in only while none has arrived.
  var visibleText: String {
    guard retainsText else {
      return ""
    }
    return doneText ?? deltaText
  }

  /// The raw arguments this item proposes, reconciled where the stream said so.
  var argumentText: String {
    guard retainsArguments else {
      return ""
    }
    return arguments ?? argumentDeltas
  }

  var budgetBytes: Int {
    SaturatingArithmetic.sum(visibleText.utf8.count, argumentText.utf8.count)
  }
}

// MARK: - Event Application

private extension ChatGPTResponsesAccumulator {
  mutating func apply(_ event: ChatGPTResponsesEvent) throws -> String? {
    switch event {
    case .outputItemAdded(let index, let item):
      try register(index: index, item: item)
      return nil
    case .outputItemDone(let index, let item):
      try complete(index: index, item: item)
      return nil
    case .outputTextDelta(let index, let text):
      return try appendText(index: index, text: text)
    case .functionCallArgumentsDelta(let index, let callID, let fragment):
      try appendArguments(index: index, callID: callID, fragment: fragment)
      return nil
    case .functionCallArgumentsDone(let index, let callID, let arguments):
      try reconcileArguments(index: index, callID: callID, arguments: arguments)
      return nil
    case .terminal, .streamError:
      // Decided by `consume`, which needs the whole batch to judge them.
      return nil
    }
  }

  /// Registers an item, or reconciles a later sighting of one. A done item may register too: it
  /// carries everything an `added` would have, so a stream that skipped the announcement is
  /// answerable rather than damaged.
  mutating func register(index: Int, item: ChatGPTStreamItem) throws {
    guard var existing = items[index] else {
      guard order.count < ChatGPTResponsesBounds.maximumOutputItems else {
        throw Self.tooManyOutputItems
      }
      items[index] = OutputItem(type: item.type, phase: item.phase, callID: item.callID)
      order.append(index)
      return
    }
    try Self.reconcile(&existing.callID, with: item.callID)
    items[index] = existing
  }

  mutating func complete(index: Int, item: ChatGPTStreamItem) throws {
    try register(index: index, item: item)
    try update(index) { accumulated in
      accumulated.done = item
      if item.type == .message {
        // The whole done text supersedes the delta assembly rather than extending it: the stream is
        // restating the message, not continuing it.
        accumulated.doneText = item.outputText.joined()
        accumulated.deltaText = ""
      }
      if let arguments = item.arguments {
        accumulated.arguments = arguments
        accumulated.argumentDeltas = ""
      }
    }
    try retainForReplay(item, at: index)
  }

  /// Publishes and retains visible text. Text for an item that can never surface is dropped as it
  /// arrives rather than buffered, so a stream of non-visible deltas cannot exhaust memory under the
  /// per-event and buffer caps. An empty delta is never published: republishing a draft with no new
  /// text would repaint it for nothing.
  mutating func appendText(index: Int, text: String) throws -> String? {
    // Text whose item was never announced has no filter to pass, and publishing it would mean
    // guessing that unannounced text is the answer.
    guard let existing = items[index] else {
      throw Self.unregisteredItem
    }
    guard existing.retainsText else {
      return nil
    }
    // Once the item's done has arrived its whole text is the source of truth, so a late delta cannot
    // add to what the owner sees. Publishing it anyway would let a streamed draft transiently exceed
    // the final answer, which excludes it. Drop it rather than buffer it.
    guard existing.done == nil else {
      return nil
    }
    try update(index) { accumulated in
      accumulated.deltaText += text
    }
    guard text.isEmpty == false else {
      return nil
    }
    return text
  }

  mutating func appendArguments(index: Int, callID: String?, fragment: String) throws {
    guard let existing = items[index] else {
      throw Self.unregisteredItem
    }
    try reconcileCallID(index: index, callID: callID)
    // Arguments for an item that proposes no call are dispatched nowhere, so they are dropped rather
    // than buffered — a stream of them cannot exhaust memory under the per-event and buffer caps.
    guard existing.retainsArguments else {
      return
    }
    try update(index) { accumulated in
      accumulated.argumentDeltas += fragment
    }
  }

  mutating func reconcileArguments(index: Int, callID: String?, arguments: String) throws {
    guard items[index] != nil else {
      throw Self.unregisteredItem
    }
    try reconcileCallID(index: index, callID: callID)
    try update(index) { accumulated in
      accumulated.arguments = arguments
      accumulated.argumentDeltas = ""
    }
  }

  mutating func reconcileCallID(index: Int, callID: String?) throws {
    guard var existing = items[index] else {
      return
    }
    try Self.reconcile(&existing.callID, with: callID)
    items[index] = existing
  }

  /// A call whose identity changes between events cannot be paired with its result, and picking a
  /// winner would attach the output to someone else's call.
  static func reconcile(_ known: inout String?, with incoming: String?) throws {
    guard let incoming, incoming.isEmpty == false else {
      return
    }
    guard let known else {
      known = incoming
      return
    }
    guard known == incoming else {
      throw conflictingCallID
    }
  }

  /// Mutates one item and re-charges the accumulated-output budget with what it now holds, so the
  /// running total is always the bytes actually retained rather than the bytes ever seen.
  mutating func update(_ index: Int, mutate: (inout OutputItem) -> Void) throws {
    guard var item = items[index] else {
      throw Self.unregisteredItem
    }
    let released = accumulatedOutputBytes - item.countedBytes
    mutate(&item)
    item.countedBytes = item.budgetBytes

    let total = SaturatingArithmetic.sum(released, item.countedBytes)
    guard total <= ChatGPTResponsesBounds.maximumAccumulatedOutputBytes else {
      throw Self.accumulatedOutputTooLarge
    }
    accumulatedOutputBytes = total
    items[index] = item
  }
}

// MARK: - Replay Retention

private extension ChatGPTResponsesAccumulator {
  /// Keeps a done item's replay material, under the same byte bound the codec would refuse it at.
  ///
  /// Applying that bound here rather than only at encoding time is what keeps a stream of very large
  /// commentary from being materialized whole on the way to being discarded. Crossing it drops every
  /// retained item rather than keeping a prefix: a partial replay is worse than none, and state loss
  /// degrades continuity, never the turn.
  mutating func retainForReplay(_ item: ChatGPTStreamItem, at index: Int) throws {
    guard replayOverflowed == false else {
      return
    }
    let weight = SaturatingArithmetic.sum(
      item.encryptedContent?.utf8.count ?? 0,
      SaturatingArithmetic.sum(
        item.outputText.reduce(0) { running, text in
          SaturatingArithmetic.sum(running, text.utf8.count)
        },
        item.summary.reduce(0) { running, text in
          SaturatingArithmetic.sum(running, text.utf8.count)
        }
      )
    )
    replayBytes = SaturatingArithmetic.sum(replayBytes, weight)
    guard replayBytes > ChatGPTProviderStateCodec.maximumStateBytes else {
      return
    }
    replayOverflowed = true
  }

  /// What the reply hands the next request to keep its reasoning coherent. Items that never resolved
  /// are simply absent: a turn does not depend on them, so they are dropped rather than guessed at.
  var replayItems: ChatGPTReplayItems {
    guard replayOverflowed == false else {
      return ChatGPTReplayItems()
    }
    var reasoning: [ChatGPTReasoningItem] = []
    var messages: [ChatGPTAssistantMessageItem] = []

    for index in order.sorted() {
      guard let accumulated = items[index], let done = accumulated.done else {
        continue
      }
      switch accumulated.type {
      case .reasoning:
        // Reasoning with nothing encrypted to replay is a handle to nothing.
        guard let encrypted = done.encryptedContent else {
          continue
        }
        reasoning.append(
          ChatGPTReasoningItem(encryptedContent: encrypted, summary: done.summary)
        )
      case .message:
        messages.append(
          ChatGPTAssistantMessageItem(
            role: done.role ?? Self.assistantRole,
            status: done.status ?? Self.completedStatus,
            phase: accumulated.phase.wireName,
            outputText: done.outputText
          )
        )
      case .functionCall, .other:
        // Calls travel as `ChatMessage.toolCalls` and are synthesized on every request, so state
        // dropped for damage or for budget can never take a tool proposal down with it.
        continue
      }
    }
    return ChatGPTReplayItems(reasoning: reasoning, assistantMessages: messages)
  }
}

// MARK: - Terminal Resolution

private extension ChatGPTResponsesAccumulator {
  static let assistantRole = "assistant"
  static let completedStatus = "completed"

  func validateNoConflict(
    with terminal: ChatGPTResponsesTerminal,
    after offset: Int,
    in events: [ChatGPTResponsesEvent]
  ) throws {
    for later in events.dropFirst(offset + 1) {
      switch later {
      case .terminal(let other):
        guard other.restates(terminal) else {
          throw Self.conflictingTerminals
        }
      case .streamError:
        throw Self.conflictingTerminals
      default:
        continue
      }
    }
  }

  /// The whole reply, or the failure the terminal states.
  func response(for terminal: ChatGPTResponsesTerminal) throws -> ChatResponse {
    switch terminal.effectiveStatus {
    case .completed:
      return try assembled(terminal, finishReason: nil)
    case .incomplete:
      // Running out of room to answer in is a short answer, not a failure: the text is real and the
      // runtime is told why it stopped.
      guard terminal.isOutputTokenLimited else {
        throw failure(terminal.failure, fallback: "the ChatGPT reply did not complete")
      }
      return try assembled(terminal, finishReason: Self.lengthFinishReason)
    case .failed, .cancelled:
      throw failure(terminal.failure, fallback: "the ChatGPT reply failed")
    }
  }

  func assembled(
    _ terminal: ChatGPTResponsesTerminal,
    finishReason: String?
  ) throws -> ChatResponse {
    let calls = try toolCalls()
    return ChatResponse(
      content: content,
      finishReason: finishReason ?? (calls.isEmpty ? Self.stopFinishReason : Self.toolFinishReason),
      usage: terminal.usage,
      // A dollar cost the route reports would be about an API plan this one is not billed under.
      costFromProvider: nil,
      toolCalls: calls,
      providerState: try codec.encodeResponseState(items: replayItems, identity: identity)
    )
  }

  /// The answer, in the stream's own order. Per item, a done item's text wins outright and the
  /// visible deltas stand in only where the backend never sent one — which is what lets a truncated
  /// turn still say what it managed to say.
  var content: String {
    order.sorted()
      .compactMap { index in
        items[index]?.visibleText
      }
      .joined()
  }

  func toolCalls() throws -> [ToolCall] {
    var calls: [ToolCall] = []
    var claimed: Set<String> = []

    for index in order.sorted() {
      guard let accumulated = items[index], accumulated.type == .functionCall else {
        continue
      }
      // A call the stream never resolved would be dispatched from truncated arguments. Unlike
      // reasoning it cannot be quietly dropped — the model asked for it.
      guard let done = accumulated.done else {
        throw Self.unresolvedFunctionCall
      }
      guard
        let callID = accumulated.callID, callID.isEmpty == false,
        let name = done.name, name.isEmpty == false
      else {
        throw Self.undispatchableFunctionCall
      }
      // Two items claiming one ID would give the dispatcher two calls it cannot tell apart, and a
      // tool result names only the ID.
      guard claimed.insert(callID).inserted else {
        throw Self.conflictingCallID
      }
      // The argument JSON stays a raw string: validating it against the tool's schema is the
      // dispatcher's job, and this side would only be guessing at it.
      calls.append(
        ToolCall(
          id: callID,
          name: name,
          argumentsJSON: accumulated.argumentText.isEmpty ? "{}" : accumulated.argumentText
        )
      )
    }
    return calls
  }
}

// MARK: - Failures

private extension ChatGPTResponsesAccumulator {
  static let lengthFinishReason = "length"
  static let stopFinishReason = "stop"
  static let toolFinishReason = "tool_calls"

  /// Every failure this type builds is terminal. Once a `data:` field byte has been consumed the
  /// turn can no longer be re-issued without risking a second bill for it, so an error class that
  /// invited a retry would contradict the policy the boundary exists to enforce.
  static func terminal(_ message: String) -> ProviderError {
    ProviderError.terminal(status: nil, message: message)
  }

  static let ambiguousEnd = terminal(
    "the ChatGPT reply ended without stating an outcome, so it may have been generated and billed"
  )

  static let conflictingTerminals = terminal(
    "the ChatGPT reply stated two different outcomes in one delivery"
  )

  static let conflictingCallID = terminal(
    "the ChatGPT reply gave one tool call two identities"
  )

  static let unresolvedFunctionCall = terminal(
    "the ChatGPT reply left a tool call unfinished"
  )

  static let undispatchableFunctionCall = terminal(
    "the ChatGPT reply proposed a tool call with no name or no call ID"
  )

  static let unregisteredItem = terminal(
    "the ChatGPT reply sent output for an item it never announced"
  )

  static let tooManyOutputItems = terminal(
    "the ChatGPT reply sent more than \(ChatGPTResponsesBounds.maximumOutputItems) output items"
  )

  static let accumulatedOutputTooLarge = terminal(
    "the ChatGPT reply exceeded "
      + "\(ChatGPTResponsesBounds.maximumAccumulatedOutputBytes) bytes of text and tool arguments"
  )

  /// A remote diagnostic on its way to an owner. It is stripped of the escape sequences that would
  /// repaint a terminal, collapsed onto one line, redacted against the credential the request
  /// carried, and bounded — in that order, so a value that only becomes a secret once its escapes
  /// are gone is still matched, and the truncation can only ever cut a placeholder.
  func failure(
    _ remote: ChatGPTRemoteFailure?,
    fallback: String = "the ChatGPT reply failed"
  ) -> ProviderError {
    guard let message = remote?.message, message.isEmpty == false else {
      return Self.terminal(fallback)
    }
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(
      message,
      redacting: redactionValues,
      maxBytes: ChatGPTProviderMetadata.maximumDiagnosticBytes
    )
    return Self.terminal("\(fallback) — \(safe)")
  }
}
