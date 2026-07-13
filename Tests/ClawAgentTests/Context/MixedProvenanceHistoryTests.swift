import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct HistoryHygieneTests {
  private func anchor(_ callIds: [String], content: String = "") -> StoredMessage {
    let calls = callIds.map { id in
      ToolCall(id: id, name: "web_fetch", argumentsJSON: "{}")
    }
    return StoredMessage(
      role: .assistant,
      content: content,
      provenance: .trusted,
      toolCallsJSON: ToolCallCoding.encode(calls)
    )
  }

  private func toolRow(_ callId: String) -> StoredMessage {
    StoredMessage(
      role: .tool,
      content: "obs \(callId)",
      provenance: .untrusted,
      toolCallId: callId
    )
  }

  private func user(_ text: String) -> StoredMessage {
    StoredMessage(role: .user, content: text, provenance: .trusted)
  }

  @Test func leadingOrphanedToolRowsAreDropped() {
    // given — a window that (through crash or corruption) starts mid-exchange
    let history = [toolRow("c0"), toolRow("c0b"), user("hello"), anchor(["c1"]), toolRow("c1")]

    // when
    let sanitized = HistoryHygiene.sanitize(history)

    // then
    #expect(sanitized.count == 3)
    #expect(sanitized[0].content == "hello")
  }

  @Test func anchorWithMissingObservationsIsDroppedWholesale() {
    // given — an anchor for c1+c2 but only c1's observation survived
    let history = [user("q"), anchor(["c1", "c2"]), toolRow("c1"), user("next")]

    // when
    let sanitized = HistoryHygiene.sanitize(history)

    // then — the partial exchange (anchor AND its stray row) is gone; a wire 400 is impossible
    #expect(sanitized.map(\.content) == ["q", "next"])
  }

  @Test func completeExchangesAndPlainRowsPassThrough() {
    // given
    let history = [
      user("q"), anchor(["c1", "c2"], content: "checking"), toolRow("c1"), toolRow("c2"),
      user("thanks"),
    ]

    // when / then
    #expect(HistoryHygiene.sanitize(history) == history)
  }
}

@Suite struct MixedProvenanceRenderingTests {
  private func makeSnapshot(_ history: [StoredMessage]) -> SessionContextSnapshot {
    SessionContextSnapshot(
      history: history,
      historyMessageIds: Array(1...Int64(history.count)),
      windowStartMessageId: nil,
      isTainted: false,
      hasPrivateData: false
    )
  }

  private func makeBuilder() -> ContextBuilder {
    ContextBuilder(
      systemPrompt: SystemPrompt.minimal,
      workspace: EmptyWorkspace(),
      memoryStore: EmptyMemoryStore(),
      retriever: EmptyRetriever(),
      budget: .default
    )
  }

  @Test func toolRowsRenderFencedWithTheToolNameLabel() throws {
    // given — a persisted exchange: anchor (raw tool_calls) + raw tool row
    let calls = [
      ToolCall(id: "c1", name: "web_fetch", argumentsJSON: #"{"url":"https://e.example/"}"#)
    ]
    let history = [
      StoredMessage(role: .user, content: "read it", provenance: .trusted),
      StoredMessage(
        role: .assistant,
        content: "checking",
        provenance: .trusted,
        toolCallsJSON: ToolCallCoding.encode(calls)
      ),
      StoredMessage(
        role: .tool,
        content: "raw page text",
        provenance: .untrusted,
        toolCallId: "c1"
      ),
      StoredMessage(role: .assistant, content: "it says hi", provenance: .trusted),
    ]

    // when
    let result = try makeBuilder().assemble(snapshot: makeSnapshot(history), sessionId: 1)

    // then — the anchor renders natively WITH its calls; the tool row renders fenced
    let anchorMessage = try #require(
      result.messages.first { message in message.role == .assistant && !message.toolCalls.isEmpty }
    )
    #expect(anchorMessage.toolCalls == calls)
    let toolMessage = try #require(result.messages.first { message in message.role == .tool })
    #expect(toolMessage.toolCallId == "c1")
    #expect(toolMessage.content.contains("<claw-untrusted"))
    #expect(toolMessage.content.contains("label=\"web_fetch\""))
    #expect(toolMessage.content.contains("raw page text"))
  }

  @Test func duplicateToolCallIdsInAnchorDoNotTrapRendering() throws {
    // given — a provider-authored anchor that (malformedly) declares the same call id twice;
    // rendering must tolerate it rather than trap building the id→name lookup (§12 contract).
    let calls = [
      ToolCall(id: "c1", name: "web_fetch", argumentsJSON: "{}"),
      ToolCall(id: "c1", name: "web_search", argumentsJSON: "{}"),
    ]
    let history = [
      StoredMessage(role: .user, content: "read it", provenance: .trusted),
      StoredMessage(
        role: .assistant,
        content: "checking",
        provenance: .trusted,
        toolCallsJSON: ToolCallCoding.encode(calls)
      ),
      StoredMessage(
        role: .tool,
        content: "raw page text",
        provenance: .untrusted,
        toolCallId: "c1"
      ),
    ]

    // when
    let result = try makeBuilder().assemble(snapshot: makeSnapshot(history), sessionId: 1)

    // then — assembly completes and the tool row's fence label resolves to one of the duplicate
    // names (the first one wins) rather than crashing
    let toolMessage = try #require(result.messages.first { message in message.role == .tool })
    #expect(toolMessage.toolCallId == "c1")
    #expect(toolMessage.content.contains("<claw-untrusted"))
    #expect(toolMessage.content.contains("label=\"web_fetch\""))
  }

  @Test func exchangeIsOneAtomicDroppableUnit() throws {
    // given — a tight history budget forcing oldest-first drops; the exchange must vanish WHOLE
    let calls = [ToolCall(id: "c1", name: "web_fetch", argumentsJSON: "{}")]
    let bigObservation = String(repeating: "x", count: 3_000)
    var history: [StoredMessage] = [
      StoredMessage(role: .user, content: "old question", provenance: .trusted),
      StoredMessage(
        role: .assistant,
        content: "",
        provenance: .trusted,
        toolCallsJSON: ToolCallCoding.encode(calls)
      ),
      StoredMessage(role: .tool, content: bigObservation, provenance: .untrusted, toolCallId: "c1"),
    ]
    history.append(
      StoredMessage(role: .user, content: "the current question", provenance: .trusted)
    )

    let tightBudget = ContextBudget(
      inputCapGraphemes: ContextBudget.default.inputCapGraphemes,
      userFileCap: 100,
      memoryFileCap: 100,
      itemsCap: 100,
      historyCap: 500,  // smaller than the exchange unit
      recallCap: 100,
      skillsCap: 100,
      recallHitCap: 100
    )
    let builder = ContextBuilder(
      systemPrompt: "p",
      workspace: EmptyWorkspace(),
      memoryStore: EmptyMemoryStore(),
      retriever: EmptyRetriever(),
      budget: tightBudget
    )

    // when
    let result = try builder.assemble(snapshot: makeSnapshot(history), sessionId: 1)

    // then — no orphaned tool message and no observation-less anchor in the wire (§12)
    let toolMessages = result.messages.filter { message in message.role == .tool }
    let anchors = result.messages.filter { message in !message.toolCalls.isEmpty }
    #expect(toolMessages.isEmpty)
    #expect(anchors.isEmpty)
    #expect(result.messages.contains { message in message.content == "the current question" })
  }

  @Test func systemPromptCarriesTheToolPolicyClauses() {
    // given / when / then (§12 row 1)
    #expect(SystemPrompt.minimal.contains("Tool use policy"))
    #expect(SystemPrompt.minimal.contains("blocked_pending_approval"))
  }
}
