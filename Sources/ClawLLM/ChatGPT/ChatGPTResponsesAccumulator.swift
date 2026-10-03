import ClawAuth
import ClawCore
import Foundation

/// Reconstructs response content and tool calls from streamed output items.
///
/// The backend can return a completed response with `output = null`. Item events supply the answer;
/// terminal events supply status, usage, and response identity. This reducer performs no I/O.
struct ChatGPTResponsesAccumulator: Sendable {
  private let codec: ChatGPTProviderStateCodec
  private let identity: ChatGPTReplayIdentity
  private let redactionValues: [String]
  private let bounds: ChatGPTResponsesBounds
  private let outputScope: AttemptOutputScope?
  private let terminalValidationPolicy: StreamingTerminalValidationPolicy
  private let progressExplanationsEnabled: Bool
  private var progress: ChatGPTResponsesProgress

  private var items: [Int: OutputItem] = [:]
  private var order: [Int] = []
  private var accumulatedOutputBytes = 0
  private var observedTokens = 0

  private var replayBytes = 0
  private var replayOverflowed = false

  private var isDecided = false
  private var pendingTerminal: ChatGPTResponsesTerminal?

  /// The redaction set is injected because this type has no credential to derive one from: the
  /// values travel with the authorization the provider used, and only the provider knows them.
  init(
    codec: ChatGPTProviderStateCodec = ChatGPTProviderStateCodec(),
    identity: ChatGPTReplayIdentity,
    redactionValues: [String] = [],
    bounds: ChatGPTResponsesBounds = .standard,
    outputScope: AttemptOutputScope? = nil,
    terminalValidationPolicy: StreamingTerminalValidationPolicy = .firstTerminal,
    progressExplanationsEnabled: Bool = false
  ) {
    self.codec = codec
    self.identity = identity
    self.redactionValues = redactionValues
    self.bounds = bounds
    self.outputScope = outputScope
    self.terminalValidationPolicy = terminalValidationPolicy
    self.progressExplanationsEnabled = progressExplanationsEnabled
    self.progress = ChatGPTResponsesProgress(bounds: bounds, secretValues: redactionValues)
  }

  /// Provides a lower-bound completion-token estimate from bounded answer text and tool arguments.
  /// Per-item rounding matches input estimation. `update(_:mutate:)` maintains the total so reads
  /// remain O(1) as the caller consumes chunks.
  var observedCompletionTokens: Int {
    observedTokens
  }

  /// Counts raw delta-buffer bytes, separate from the visible-output budget.
  /// Memory-bound tests use this to verify that the reducer discards irrelevant deltas.
  var retainedDeltaBytes: Int {
    order.reduce(0) { totalBytes, index in
      guard let item = items[index] else {
        return totalBytes
      }

      let itemDeltaBytes = SaturatingArithmetic.sum(
        item.deltaText.utf8.count,
        item.argumentDeltas.utf8.count
      )

      return SaturatingArithmetic.sum(totalBytes, itemDeltaBytes)
    }
  }

  /// Emits answer deltas, optional progress, and the completed response for one decoded batch.
  /// The default policy resolves the first terminal after checking the rest of that batch for
  /// contradictions. Evaluation-only strict validation defers the response until EOF.
  mutating func consume(_ events: [ChatGPTResponsesEvent]) throws -> [StreamEvent] {
    guard isDecided == false else {
      return []
    }

    if let pendingTerminal {
      self.pendingTerminal = try reconciledTerminal(with: pendingTerminal, in: events[...])
      return []
    }

    var emittedEvents: [StreamEvent] = []
    for (offset, event) in events.enumerated() {
      switch event {
      case .terminal(let terminal):
        let reconciled = try reconciledTerminal(with: terminal, after: offset, in: events)
        if terminalValidationPolicy == .throughStreamEnd {
          pendingTerminal = reconciled
          emittedEvents += try progress.finish()
          return emittedEvents
        }

        isDecided = true
        let completedResponse = try response(for: reconciled)
        emittedEvents += try progress.finish()
        emittedEvents.append(.finished(completedResponse))

        return emittedEvents
      case .streamError(let remoteFailure):
        isDecided = true
        throw failure(remoteFailure)
      default:
        emittedEvents += try apply(event)
      }
    }
    return emittedEvents
  }

  /// Resolves a pending strict-mode terminal at EOF, or rejects a stream with no terminal.
  /// The caller uses `observedCompletionTokens` to account for a potentially billed partial reply.
  mutating func finish() throws -> StreamEvent? {
    guard isDecided == false else {
      return nil
    }
    isDecided = true

    if let pendingTerminal {
      return .finished(try response(for: pendingTerminal))
    }

    throw Self.ambiguousEnd
  }
}

// MARK: - Accumulated Item

/// Tracks one output item's text, arguments, and contribution to byte/token budgets.
/// Completed values replace delta assemblies without charging both versions.
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
  /// This item's contribution to the running completion-token estimate, recomputed alongside
  /// `countedBytes` when the item changes so the accumulator's per-chunk read stays O(1).
  var tokenEstimate = 0

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

  /// The completion tokens this item's visible text and tool arguments estimate to, each rounded on
  /// its own so the per-item headroom matches the summed-per-message input estimate.
  var estimatedTokens: Int {
    SaturatingArithmetic.sum(
      TokenEstimator.estimateTokens(forText: visibleText),
      TokenEstimator.estimateTokens(forText: argumentText)
    )
  }
}

// MARK: - Event Application

private extension ChatGPTResponsesAccumulator {
  mutating func apply(_ event: ChatGPTResponsesEvent) throws -> [StreamEvent] {
    switch event {
    case .outputItemAdded(let index, let item):
      try register(index: index, item: item)
      return []
    case .outputItemDone(let index, let item):
      return try applyCompletedItem(index: index, item: item)
    case .outputTextDelta(let index, let text):
      let answerDelta = try appendText(index: index, text: text)
      if let answerDelta {
        return [.delta(answerDelta)]
      }
      return try commentary(index: index, text: .append(text))
    case .outputTextDone(let index, let text):
      var events = try commentary(index: index, text: .replace(text))
      events += try commentary(index: index, text: .complete)
      return events
    case .summaryTextDelta(let index, let part, let text):
      return try summary(index: index, part: part, text: .append(text))
    case .summaryTextDone(let index, let part, let text):
      var events = try summary(index: index, part: part, text: .replace(text))
      events += try summary(index: index, part: part, text: .complete)
      return events
    case .summaryPart(let index, let part, let text, let completed):
      return try applySummaryPart(index: index, part: part, text: text, completed: completed)
    case .functionCallArgumentsDelta(let index, let callID, let fragment):
      try appendArguments(index: index, callID: callID, fragment: fragment)
      return []
    case .functionCallArgumentsDone(let index, let callID, let arguments):
      try reconcileArguments(index: index, callID: callID, arguments: arguments)
      return []
    case .terminal, .streamError:
      // `consume` checks terminal events against the rest of the decoded batch.
      return []
    }
  }

  mutating func applyCompletedItem(index: Int, item: ChatGPTStreamItem) throws -> [StreamEvent] {
    if let existing = items[index] {
      let isExplanation = existing.type == .reasoning || existing.phase == .commentary
      if existing.done != nil && isExplanation {
        try register(index: index, item: item)
        return []
      }
    }

    try complete(index: index, item: item)
    return try completedProgress(index: index, item: item)
  }

  mutating func applySummaryPart(
    index: Int,
    part: Int,
    text: String?,
    completed: Bool
  ) throws -> [StreamEvent] {
    guard let text else {
      return []
    }

    var events = try summary(index: index, part: part, text: .replace(text))
    if completed {
      events += try summary(index: index, part: part, text: .complete)
    }

    return events
  }
}

// MARK: - Output Item Updates

private extension ChatGPTResponsesAccumulator {
  /// Registers an item, or reconciles a later sighting of one. A done item may register too: it
  /// carries everything an `added` would have, so a stream that skipped the announcement is
  /// answerable rather than damaged.
  mutating func register(index: Int, item: ChatGPTStreamItem) throws {
    guard var existing = items[index] else {
      guard order.count < bounds.maximumOutputItems else {
        throw tooManyOutputItems
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

    try retainForReplay(item)
  }

  /// Retains answer deltas for visible, unfinished items. Suppresses empty deltas and discards
  /// text for hidden or completed items so unused delta buffers cannot grow.
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
}

// MARK: - Output Accounting

private extension ChatGPTResponsesAccumulator {
  /// Replaces an item's budget contribution after mutation, rather than counting both versions.
  mutating func update(_ index: Int, mutate: (_ item: inout OutputItem) -> Void) throws {
    guard var item = items[index] else {
      throw Self.unregisteredItem
    }

    let otherItemBytes = accumulatedOutputBytes - item.countedBytes
    let otherItemTokens = observedTokens - item.tokenEstimate
    mutate(&item)
    item.countedBytes = item.budgetBytes
    item.tokenEstimate = item.estimatedTokens

    let updatedOutputBytes = SaturatingArithmetic.sum(otherItemBytes, item.countedBytes)
    try validateOutputBudget(outputBytes: updatedOutputBytes)

    accumulatedOutputBytes = updatedOutputBytes
    observedTokens = SaturatingArithmetic.sum(otherItemTokens, item.tokenEstimate)
    items[index] = item
    try outputScope?.observe(fields: currentOutputFields)
  }

  func validateOutputBudget(outputBytes: Int) throws {
    let totalRetainedBytes = SaturatingArithmetic.sum(outputBytes, progress.retainedTextBytes)
    guard totalRetainedBytes <= bounds.maximumAccumulatedOutputBytes else {
      throw accumulatedOutputTooLarge
    }
  }

  var currentOutputFields: [AttemptOutputField] {
    order
      .sorted()
      .flatMap { index -> [AttemptOutputField] in
        guard let item = items[index] else {
          return []
        }

        var fields: [AttemptOutputField] = []

        let answerText = item.visibleText
        if !answerText.isEmpty {
          fields.append(AttemptOutputField(key: "responses-visible:\(index)", value: answerText))
        }

        if item.retainsArguments {
          fields.append(
            AttemptOutputField(key: "responses-tool-arguments:\(index)", value: item.argumentText)
          )
        }

        return fields
      }
  }
}

// MARK: - Display Explanations

private extension ChatGPTResponsesAccumulator {
  mutating func commentary(index: Int, text: LLMProgressText) throws -> [StreamEvent] {
    guard progressExplanationsEnabled,
          let item = items[index], item.type == .message, item.phase == .commentary,
          item.done == nil
    else {
      return []
    }
    return try updateProgress(index: index, part: nil, kind: .commentary, text: text)
  }

  mutating func summary(index: Int, part: Int, text: LLMProgressText) throws -> [StreamEvent] {
    guard progressExplanationsEnabled else {
      return []
    }

    guard let item = items[index] else {
      throw Self.unregisteredItem
    }

    guard item.type == .reasoning, item.done == nil else {
      return []
    }

    return try updateProgress(index: index, part: part, kind: .summary, text: text)
  }

  mutating func completedProgress(index: Int, item: ChatGPTStreamItem) throws -> [StreamEvent] {
    guard progressExplanationsEnabled, let accumulated = items[index] else {
      return []
    }

    var events: [StreamEvent] = []
    if accumulated.type == .message, accumulated.phase == .commentary {
      events += try updateProgress(
        index: index,
        part: nil,
        kind: .commentary,
        text: .replace(item.outputText.joined())
      )
      events += try updateProgress(index: index, part: nil, kind: .commentary, text: .complete)
    } else if accumulated.type == .reasoning {
      for part in item.summaryTextParts.keys.sorted() {
        guard let text = item.summaryTextParts[part] else {
          continue
        }

        events += try updateProgress(index: index, part: part, kind: .summary, text: .replace(text))
        events += try updateProgress(index: index, part: part, kind: .summary, text: .complete)
      }
    }

    return events
  }

  mutating func updateProgress(
    index: Int,
    part: Int?,
    kind: LLMProgressKind,
    text: LLMProgressText
  ) throws -> [StreamEvent] {
    let events = try progress.update(index: index, part: part, kind: kind, text: text)
    try validateOutputBudget(outputBytes: accumulatedOutputBytes)
    return events
  }
}

// MARK: - Replay Retention

private extension ChatGPTResponsesAccumulator {
  /// Tracks completed replay bytes and disables replay serialization above the codec's cap.
  /// Completed items remain in the accumulator for response assembly; overflow emits empty replay
  /// state rather than a partial prefix and does not fail the response.
  mutating func retainForReplay(_ item: ChatGPTStreamItem) throws {
    guard replayOverflowed == false else {
      return
    }

    let encryptedBytes = item.encryptedContent?.utf8.count ?? 0
    let outputTextBytes = item.outputText.reduce(0) { totalBytes, text in
      SaturatingArithmetic.sum(totalBytes, text.utf8.count)
    }
    let summaryBytes = item.summary.reduce(0) { totalBytes, text in
      SaturatingArithmetic.sum(totalBytes, text.utf8.count)
    }

    let textBytes = SaturatingArithmetic.sum(outputTextBytes, summaryBytes)
    let itemReplayBytes = SaturatingArithmetic.sum(encryptedBytes, textBytes)
    replayBytes = SaturatingArithmetic.sum(replayBytes, itemReplayBytes)

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

        reasoning.append(ChatGPTReasoningItem(encryptedContent: encrypted, summary: done.summary))
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

  func reconciledTerminal(
    with terminal: ChatGPTResponsesTerminal,
    after offset: Int,
    in events: [ChatGPTResponsesEvent]
  ) throws -> ChatGPTResponsesTerminal {
    try reconciledTerminal(with: terminal, in: events.dropFirst(offset + 1))
  }

  func reconciledTerminal(
    with terminal: ChatGPTResponsesTerminal,
    in events: ArraySlice<ChatGPTResponsesEvent>
  ) throws -> ChatGPTResponsesTerminal {
    var reconciled = terminal

    for event in events {
      switch event {
      case .terminal(let laterTerminal):
        if terminalValidationPolicy == .throughStreamEnd,
           let expectedModel = reconciled.reportedModel,
           let reportedModel = laterTerminal.reportedModel,
           expectedModel != reportedModel
        {
          throw ProviderError.modelIdentityMismatch
        }

        guard laterTerminal.restates(reconciled) else {
          throw Self.conflictingTerminals
        }

        if terminalValidationPolicy == .throughStreamEnd {
          let reportedModel = reconciled.reportedModel ?? laterTerminal.reportedModel
          reconciled = reconciled.withReportedModel(reportedModel)
        }
      case .streamError:
        throw Self.conflictingTerminals
      default:
        break
      }
    }

    return reconciled
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
    let defaultFinishReason = calls.isEmpty ? Self.stopFinishReason : Self.toolFinishReason
    let providerState = try codec.encodeResponseState(items: replayItems, identity: identity)

    return ChatResponse(
      content: content,
      finishReason: finishReason ?? defaultFinishReason,
      usage: terminal.usage,
      // A dollar cost the route reports would be about an API plan this one is not billed under.
      costFromProvider: nil,
      toolCalls: calls,
      providerState: providerState,
      reportedModel: terminal.reportedModel
    )
  }

  /// Assembles answer text in output-index order, preferring completed text over deltas.
  /// Delta-only items still contribute to a token-limited response.
  var content: String {
    order
      .sorted()
      .compactMap { index in
        items[index]?.visibleText
      }
      .joined()
  }

  func toolCalls() throws -> [ToolCall] {
    var calls: [ToolCall] = []
    var claimedCallIDs: Set<String> = []

    for index in order.sorted() {
      guard let accumulated = items[index], accumulated.type == .functionCall else {
        continue
      }
      // A call the stream never resolved would be dispatched from truncated arguments. Unlike
      // reasoning it cannot be quietly dropped — the model asked for it.
      guard let done = accumulated.done else {
        throw Self.unresolvedFunctionCall
      }

      guard let callID = accumulated.callID,
            callID.isEmpty == false,
            let name = done.name,
            name.isEmpty == false
      else {
        throw Self.undispatchableFunctionCall
      }
      // Two items claiming one ID would give the dispatcher two calls it cannot tell apart, and a
      // tool result names only the ID.
      let isNewCallID = claimedCallIDs.insert(callID).inserted
      guard isNewCallID else {
        throw Self.conflictingCallID
      }
      // The dispatcher validates raw argument JSON against the tool's schema.
      let argumentText = accumulated.argumentText
      let argumentsJSON = argumentText.isEmpty ? "{}" : argumentText
      calls.append(ToolCall(id: callID, name: name, argumentsJSON: argumentsJSON))
    }

    return calls
  }
}

// MARK: - Failures

private extension ChatGPTResponsesAccumulator {
  static let lengthFinishReason = "length"
  static let stopFinishReason = "stop"
  static let toolFinishReason = "tool_calls"

  /// Every failure this type builds is terminal. An accepted response may already have generated
  /// tokens, so inviting a retry would risk charging for the same turn twice.
  static func terminal(_ message: String) -> ProviderError {
    ProviderError.terminal(status: nil, message: message)
  }

  /// EOF without an in-band terminal is the protocol's one specifically named partial-stream
  /// carrier failure. It remains conservative and is never retried by this provider; the opt-in
  /// evaluation harness may use the payload-free cause to replace the whole attempt once.
  static let ambiguousEnd = ProviderError.partialStreamWithoutCompletedTerminal

  static let conflictingTerminals = terminal("the ChatGPT reply stated conflicting outcomes")

  static let conflictingCallID = terminal("the ChatGPT reply gave one tool call two identities")

  static let unresolvedFunctionCall = terminal("the ChatGPT reply left a tool call unfinished")

  static let undispatchableFunctionCall = terminal(
    "the ChatGPT reply proposed a tool call with no name or no call ID"
  )

  static let unregisteredItem = terminal(
    "the ChatGPT reply sent output for an item it never announced"
  )

  var tooManyOutputItems: ProviderError {
    Self.terminal("the ChatGPT reply sent more than \(bounds.maximumOutputItems) output items")
  }

  var accumulatedOutputTooLarge: ProviderError {
    Self.terminal(
      """
      the ChatGPT reply exceeded \(bounds.maximumAccumulatedOutputBytes) bytes \
      of text and tool arguments
      """
    )
  }

  /// Builds a terminal error with a normalized, redacted, bounded remote diagnostic.
  /// Diagnostic normalization precedes redaction, and redaction precedes truncation.
  func failure(
    _ remote: ChatGPTRemoteFailure?,
    fallback: String = "the ChatGPT reply failed"
  ) -> ProviderError {
    // The backend refusing the replayed encrypted state is not a generic terminal: a fresh session
    // drops that state, so it surfaces as invalid replay state and its downstream `/new` guidance.
    if remote?.isInvalidProviderState == true {
      return .invalidProviderState
    }

    guard let message = remote?.message, message.isEmpty == false else {
      return Self.terminal(fallback)
    }

    let safeDiagnostic = ChatGPTProviderMetadata.safeDiagnostic(message, redacting: redactionValues)
    return Self.terminal("\(fallback) — \(safeDiagnostic)")
  }
}
