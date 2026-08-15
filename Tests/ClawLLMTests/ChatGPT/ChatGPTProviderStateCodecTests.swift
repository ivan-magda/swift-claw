import ClawCore
import Foundation
import Testing

@testable import ClawLLM

/// The replay codec's two halves, asserted against the specified encoding rather than against
/// itself: the issuer goldens below were derived with `shasum -a 256` outside this process, so the
/// two agreeing means the identity is the one the design pins rather than merely self-consistent.
@Suite struct ChatGPTProviderStateCodecTests {
  // MARK: - Identity

  /// The whole issuer, byte for byte. Every other compatibility test leans on this one being the
  /// specified string and not just a reproducible one.
  @Test func issuerMatchesTheGoldenVector() {
    // given
    let identity = ChatGPTReplayIdentity(
      profileID: Self.profileID,
      wireModel: Self.wireModel,
      epoch: Self.epoch
    )

    // when
    let issuer = identity.issuer

    // then
    #expect(issuer == Self.goldenIssuer)
  }

  /// The hashes are a function of the profile ID and the model text alone, so the same pair renders
  /// the same identity on every process — the property the derive-on-restart rule rests on.
  @Test func profileAndModelHashesAreStable() {
    // given
    let first = ChatGPTReplayIdentity(
      profileID: Self.profileID,
      wireModel: Self.wireModel,
      epoch: Self.epoch
    )
    let second = ChatGPTReplayIdentity(
      profileID: Self.profileID,
      wireModel: Self.wireModel,
      epoch: Self.otherEpoch
    )

    // then
    #expect(first.credentialProfileHash == second.credentialProfileHash)
    #expect(first.wireModelHash == second.wireModelHash)
    #expect(first.credentialProfileHash == "11e594f481958c10e3015d0bf0447a22")
    #expect(first.wireModelHash == "b0a9d642d12f553129c39513f7ce2605")
  }

  /// The issuer travels no further than this daemon's own database, but it is still an identity: a
  /// value that is exactly a fixed version and three hashed fields has nowhere to hide the profile
  /// or the account the state was minted for.
  @Test func issuerCarriesNoProfileOrAccountIdentifier() {
    // given
    let identity = ChatGPTReplayIdentity(
      profileID: Self.profileID,
      wireModel: Self.wireModel,
      epoch: Self.epoch
    )

    // when
    let issuer = identity.issuer

    // then
    #expect(issuer.contains(Self.profileID.uuidString) == false)
    #expect(issuer.contains(Self.profileID.uuidString.lowercased()) == false)
    #expect(issuer.contains(Self.wireModel) == false)

    let fields = issuer.split(separator: ":", omittingEmptySubsequences: false)
    #expect(fields.count == 4)
    #expect(fields[0] == "openai-chatgpt-responses-v1")
    for hash in fields[1...2] {
      #expect(hash.count == 32)
      #expect(
        hash.allSatisfy { character in
          character.isHexDigit && character.isUppercase == false
        }
      )
    }
    #expect(fields[3] == Self.epoch.uuidString.lowercased())
  }

  // MARK: - Compatibility

  /// A refresh swaps the access token and leaves the profile ID alone, so the state a prior turn
  /// minted is still ours. This is the positive half of the re-login pair below: without it, a codec
  /// that dropped every state would pass the negative on its own.
  @Test func refreshKeepsPriorStateReplayable() throws {
    // given
    let identity = Self.identity(epoch: Self.epoch)
    let history = [
      ChatMessage(role: .user, content: "hello"),
      ChatMessage(
        role: .assistant,
        content: "hi",
        providerState: try Self.state(reasoning: "ENC", identity: identity)
      ),
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.identity.epoch == Self.epoch)
    #expect(selection.turns.keys.sorted() == [1])
    #expect(selection.drops.isEmpty)
  }

  /// Re-login mints a new profile ID, which is the only thing the hash is derived from — so every
  /// state the old profile minted reads as another origin's and is left behind.
  @Test func reloginMakesPriorStateForeign() throws {
    // given
    let history = [
      ChatMessage(
        role: .assistant,
        content: "hi",
        providerState: try Self.state(reasoning: "ENC", identity: Self.identity(epoch: Self.epoch))
      )
    ]
    let mintedEpoch = Self.fixedUUID("99999999-9999-4999-8999-999999999999")

    // when
    let selection = Self.codec(newEpoch: mintedEpoch).decodeCompatibleHistory(
      messages: history,
      profileID: Self.reloginProfileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.turns.isEmpty)
    #expect(selection.drops.foreign == 1)
    #expect(selection.identity.epoch == mintedEpoch)
    #expect(selection.identity.credentialProfileHash == "e79acd97ac88086665d85a762f43d533")
  }

  /// A model switch changes what the encrypted reasoning was produced by, so state minted under the
  /// other model is not replayable even for the same owner.
  @Test func wrongModelIsForeign() throws {
    // given
    let history = [
      ChatMessage(
        role: .assistant,
        content: "hi",
        providerState: try Self.state(reasoning: "ENC", identity: Self.identity(epoch: Self.epoch))
      )
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: "gpt-5-codex"
    )

    // then
    #expect(selection.turns.isEmpty)
    #expect(selection.drops.foreign == 1)
  }

  /// Every issuer this codec cannot read as its own. The four fields are checked together, so a
  /// state from another provider, another version, or a corrupted row is left where it lies rather
  /// than being sent somewhere it does not belong.
  @Test(arguments: [
    // Another provider entirely.
    "openai-chat-completions-v1:11e594f481958c10e3015d0bf0447a22:b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111",
    // A future version of this route.
    "openai-chatgpt-responses-v2:11e594f481958c10e3015d0bf0447a22:b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111",
    // Too few fields.
    "openai-chatgpt-responses-v1:11e594f481958c10e3015d0bf0447a22:11111111-1111-4111-8111-111111111111",
    // Too many fields.
    "openai-chatgpt-responses-v1:11e594f481958c10e3015d0bf0447a22:b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111:extra",
    // A hash that is not hex.
    "openai-chatgpt-responses-v1:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz:b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111",
    // A hash of the wrong width.
    "openai-chatgpt-responses-v1:11e594f4:b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111",
    // Uppercase hex, which the canonical rendering never produces.
    "openai-chatgpt-responses-v1:11E594F481958C10E3015D0BF0447A22:b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111",
    // An uppercase epoch, likewise not the canonical form.
    "openai-chatgpt-responses-v1:11e594f481958c10e3015d0bf0447a22:b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111"
      .uppercased(),
    // An epoch that is not a UUID.
    "openai-chatgpt-responses-v1:11e594f481958c10e3015d0bf0447a22:b0a9d642d12f553129c39513f7ce2605:not-a-uuid",
    // Empty.
    "",
  ])
  func malformedOrForeignIssuersAreDropped(_ issuer: String) throws {
    // given
    let payload = try Self.state(reasoning: "ENC", identity: Self.identity(epoch: Self.epoch))
    let history = [
      ChatMessage(
        role: .assistant,
        content: "hi",
        providerState: ProviderExchangeState(issuer: issuer, payload: payload.payload)
      )
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.turns.isEmpty)
    #expect(selection.drops.foreign == 1)
  }

  /// The epoch is derived from the newest compatible state, and only that epoch replays. An older
  /// epoch in the same history is the poisoned material a recovery walked away from; replaying it
  /// would undo the recovery.
  @Test func onlyTheNewestCompatibleEpochIsReplayed() throws {
    // given
    let history = [
      ChatMessage(
        role: .assistant,
        content: "old",
        providerState: try Self.state(reasoning: "OLD", identity: Self.identity(epoch: Self.epoch))
      ),
      ChatMessage(role: .user, content: "again"),
      ChatMessage(
        role: .assistant,
        content: "new",
        providerState: try Self.state(
          reasoning: "NEW",
          identity: Self.identity(epoch: Self.otherEpoch)
        )
      ),
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.identity.epoch == Self.otherEpoch)
    #expect(selection.turns.keys.sorted() == [2])
    #expect(selection.turns[2]?.reasoning.first?.encryptedContent == "NEW")
    #expect(selection.drops.staleEpoch == 1)
  }

  /// Two states of one epoch both replay. Paired with the test above, this is what separates
  /// "newest epoch only" from "newest state only".
  @Test func everyStateOfTheNewestEpochIsReplayed() throws {
    // given
    let identity = Self.identity(epoch: Self.epoch)
    let history = [
      ChatMessage(
        role: .assistant,
        content: "one",
        providerState: try Self.state(reasoning: "ONE", identity: identity)
      ),
      ChatMessage(role: .user, content: "again"),
      ChatMessage(
        role: .assistant,
        content: "two",
        providerState: try Self.state(reasoning: "TWO", identity: identity)
      ),
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.turns.keys.sorted() == [0, 2])
    #expect(selection.drops.isEmpty)
  }

  /// A history with nothing of ours in it starts an epoch rather than borrowing one.
  @Test func historyWithoutCompatibleStateMintsAFreshEpoch() {
    // given
    let minted = Self.fixedUUID("77777777-7777-4777-8777-777777777777")
    let history = [
      ChatMessage(role: .user, content: "hello"),
      ChatMessage(role: .assistant, content: "hi"),
    ]

    // when
    let selection = Self.codec(newEpoch: minted).decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.identity.epoch == minted)
    #expect(selection.turns.isEmpty)
    #expect(selection.drops.isEmpty)
  }

  // MARK: - Malformed payloads

  /// The store keeps opaque bytes and cannot judge them, so this is the only place a payload that is
  /// not our shape can be caught. Each of these decodes to nothing and costs the session its state
  /// rather than its turn.
  @Test(arguments: [
    // Not JSON at all — the bytes a truncated or clobbered row would carry.
    Data([0xFF, 0xFE, 0x00, 0x28, 0xC3]),
    // Valid JSON, wrong shape.
    Data(#"{"foo":1}"#.utf8),
    // Valid JSON, wrong root type.
    Data("[]".utf8),
    // Truncated mid-object.
    Data(#"{"assistant_messages":[],"reason"#.utf8),
    // Our keys, but a reasoning item claiming another type.
    Data(#"{"assistant_messages":[],"reasoning":[{"encrypted_content":"E","type":"note"}]}"#.utf8),
    // Our keys, but a reasoning item missing the content that is the whole point of it.
    Data(#"{"assistant_messages":[],"reasoning":[{"type":"reasoning"}]}"#.utf8),
    // Empty bytes.
    Data(),
  ])
  func malformedPayloadJSONIsDropped(_ payload: Data) {
    // given
    let history = [
      ChatMessage(
        role: .assistant,
        content: "hi",
        providerState: ProviderExchangeState(
          issuer: Self.identity(epoch: Self.epoch).issuer,
          payload: payload
        )
      )
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.turns.isEmpty)
    #expect(selection.drops.malformed == 1)
  }

  /// A malformed newest state must not set the epoch either: it is not compatible, so the epoch is
  /// derived from the newest state that actually decodes.
  @Test func malformedStateDoesNotSetTheEpoch() throws {
    // given
    let history = [
      ChatMessage(
        role: .assistant,
        content: "good",
        providerState: try Self.state(reasoning: "OK", identity: Self.identity(epoch: Self.epoch))
      ),
      ChatMessage(
        role: .assistant,
        content: "bad",
        providerState: ProviderExchangeState(
          issuer: Self.identity(epoch: Self.otherEpoch).issuer,
          payload: Data("not json".utf8)
        )
      ),
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.identity.epoch == Self.epoch)
    #expect(selection.turns.keys.sorted() == [0])
    #expect(selection.drops.malformed == 1)
  }

  /// An empty payload is a real state, not a missing one: it is what a state-free recovery stamps,
  /// and it must carry its epoch forward exactly like a populated one.
  @Test func emptyPayloadStateIsCompatibleAndCarriesItsEpoch() throws {
    // given
    let identity = Self.identity(epoch: Self.otherEpoch)
    let history = [
      ChatMessage(
        role: .assistant,
        content: "hi",
        providerState: try Self.codec().encodeResponseState(
          items: ChatGPTReplayItems(),
          identity: identity
        )
      )
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.identity.epoch == Self.otherEpoch)
    #expect(selection.turns[0] != nil)
    #expect(selection.turns[0]?.reasoning.isEmpty == true)
    #expect(selection.drops.isEmpty)
  }

  // MARK: - Diagnostics

  /// A session degrading to stateless replay is invisible without this. The selection carries the
  /// reasons counted, in a type with no field a payload or an issuer could travel in — which is what
  /// keeps the warning from becoming the leak it is warning about.
  @Test func everyDropReasonIsCountedOnTheSelection() throws {
    // given
    let codec = Self.codec()
    let history = [
      ChatMessage(
        role: .assistant,
        content: "stale",
        providerState: try Self.state(reasoning: "OLD", identity: Self.identity(epoch: Self.epoch))
      ),
      ChatMessage(
        role: .assistant,
        content: "alien",
        providerState: ProviderExchangeState(
          issuer: "some-other-provider:whatever",
          payload: Data("{}".utf8)
        )
      ),
      ChatMessage(
        role: .assistant,
        content: "corrupt",
        providerState: ProviderExchangeState(
          issuer: Self.identity(epoch: Self.otherEpoch).issuer,
          payload: Data([0xFF, 0xFE])
        )
      ),
      ChatMessage(
        role: .assistant,
        content: "good",
        providerState: try Self.state(
          reasoning: "NEW",
          identity: Self.identity(epoch: Self.otherEpoch)
        )
      ),
    ]

    // when
    let selection = codec.decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.drops.foreign == 1)
    #expect(selection.drops.malformed == 1)
    #expect(selection.drops.staleEpoch == 1)
    #expect(selection.drops.total == 3)
  }

  /// Nothing dropped means nothing said: the provider logs only a non-empty count, so a warning on
  /// every clean history would train the owner to ignore the one that matters.
  @Test func cleanHistoryReportsNoDrops() throws {
    // given
    let history = [
      ChatMessage(
        role: .assistant,
        content: "hi",
        providerState: try Self.state(reasoning: "ENC", identity: Self.identity(epoch: Self.epoch))
      )
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.drops.isEmpty)
  }

  // MARK: - Normalization

  /// The durable payload, byte for byte. It is two arrays under sorted keys and nothing else — no
  /// item IDs, because `store: false` leaves the backend unable to resolve them on the replay this
  /// payload exists to feed.
  @Test func encodedPayloadMatchesTheGoldenVector() throws {
    // given
    let items = ChatGPTReplayItems(
      reasoning: [
        ChatGPTReasoningItem(encryptedContent: "ENC", summary: ["thought"])
      ],
      assistantMessages: [
        ChatGPTAssistantMessageItem(
          role: "assistant",
          status: "completed",
          phase: "final",
          outputText: ["hi"]
        )
      ]
    )

    // when
    let state = try Self.codec().encodeResponseState(
      items: items,
      identity: Self.identity(epoch: Self.epoch)
    )

    // then
    #expect(state.issuer == Self.goldenIssuer)
    #expect(
      try Self.rendered(state) == """
        {"assistant_messages":[{"content":[{"text":"hi","type":"output_text"}],"phase":"final",\
        "role":"assistant","status":"completed","type":"message"}],"reasoning":\
        [{"encrypted_content":"ENC","summary":["thought"],"type":"reasoning"}]}
        """
    )
  }

  /// The stamp a recovery leaves when the response carried no reasoning at all.
  @Test func emptyItemsEncodeToTheEmptyGoldenPayload() throws {
    // given
    let identity = Self.identity(epoch: Self.epoch)

    // when
    let state = try Self.codec().encodeResponseState(
      items: ChatGPTReplayItems(),
      identity: identity
    )

    // then
    #expect(
      try Self.rendered(state)
        == #"{"assistant_messages":[],"reasoning":[]}"#
    )
  }

  /// No server item ID ever reaches the persisted payload: the durable shape carries no `id` key, and
  /// the round-trip proves the material it does carry survives intact.
  @Test func serverItemIDsAreRemovedBeforePersistence() throws {
    // given
    let items = ChatGPTReplayItems(
      reasoning: [
        ChatGPTReasoningItem(encryptedContent: "ENC", summary: ["s"])
      ],
      assistantMessages: [
        ChatGPTAssistantMessageItem(outputText: ["hi"])
      ]
    )

    // when
    let state = try Self.codec().encodeResponseState(
      items: items,
      identity: Self.identity(epoch: Self.epoch)
    )
    let rendered = try Self.rendered(state)
    let decoded = try #require(Self.decodeItems(state))

    // then
    #expect(rendered.contains("\"id\"") == false)
    #expect(decoded.reasoning.first?.encryptedContent == "ENC")
    #expect(decoded.reasoning.first?.summary == ["s"])
    #expect(decoded.assistantMessages.first?.outputText == ["hi"])
  }

  /// A provider that omits the summary leaves an empty array, not a missing key: the replayed item
  /// has to be the shape the route reads back.
  @Test func reasoningSummaryDefaultsToEmpty() throws {
    // given
    let payload = Data(
      #"{"assistant_messages":[],"reasoning":[{"encrypted_content":"ENC","type":"reasoning"}]}"#
        .utf8
    )
    let state = ProviderExchangeState(
      issuer: Self.identity(epoch: Self.epoch).issuer,
      payload: payload
    )

    // when
    let decoded = try #require(Self.decodeItems(state))

    // then
    #expect(decoded.reasoning.first?.summary == [])
  }

  /// Phase is written only when the provider stated one — pairing the two halves so that neither
  /// "always present" nor "always absent" passes.
  @Test func assistantPhaseIsEncodedOnlyWhenPresent() throws {
    // given
    let withPhase = ChatGPTReplayItems(
      assistantMessages: [ChatGPTAssistantMessageItem(phase: "final", outputText: ["hi"])]
    )
    let withoutPhase = ChatGPTReplayItems(
      assistantMessages: [ChatGPTAssistantMessageItem(outputText: ["hi"])]
    )
    let identity = Self.identity(epoch: Self.epoch)

    // when
    let present = try Self.codec().encodeResponseState(items: withPhase, identity: identity)
    let absent = try Self.codec().encodeResponseState(items: withoutPhase, identity: identity)

    // then
    #expect(try Self.rendered(present).contains(#""phase":"final""#))
    #expect(try Self.rendered(absent).contains("phase") == false)
    #expect(Self.decodeItems(present)?.assistantMessages.first?.phase == "final")
    #expect(Self.decodeItems(absent)?.assistantMessages.first?.phase == nil)
  }

  /// The payload is two arrays and no third. A tool proposal that lived in here would be a proposal
  /// the request loses the moment its state is dropped for budget or corruption.
  @Test func functionCallsAreNeverStoredInState() throws {
    // given
    let items = ChatGPTReplayItems(
      reasoning: [ChatGPTReasoningItem(encryptedContent: "ENC")],
      assistantMessages: [ChatGPTAssistantMessageItem(outputText: ["calling a tool"])]
    )

    // when
    let state = try Self.codec().encodeResponseState(
      items: items,
      identity: Self.identity(epoch: Self.epoch)
    )
    let rendered = try Self.rendered(state)
    let root = try #require(
      try JSONSerialization.jsonObject(with: state.payload) as? [String: Any]
    )

    // then
    #expect(root.keys.sorted() == ["assistant_messages", "reasoning"])
    #expect(rendered.contains("function_call") == false)
    #expect(rendered.contains("call_id") == false)
  }

  /// The rule the whole normalization exists to protect: state substitutes for the assistant text a
  /// turn would otherwise synthesize, and the calls travel beside it untouched. A codec that let
  /// state stand for the whole turn would silently drop the tool proposal.
  @Test func stateReplacesSynthesizedTextButNeverFunctionCalls() throws {
    // given
    let calls = [
      ToolCall(id: "call_1", name: "web_fetch", argumentsJSON: #"{"url":"https://example.com"}"#),
      ToolCall(id: "call_2", name: "clock", argumentsJSON: "{}"),
    ]
    let items = ChatGPTReplayItems(
      reasoning: [ChatGPTReasoningItem(encryptedContent: "ENC")],
      assistantMessages: [ChatGPTAssistantMessageItem(outputText: ["let me look"])]
    )
    let history = [
      ChatMessage(
        role: .assistant,
        content: "let me look",
        toolCalls: calls,
        providerState: try Self.codec().encodeResponseState(
          items: items,
          identity: Self.identity(epoch: Self.epoch)
        )
      )
    ]

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    let turn = try #require(selection.turns[0])
    #expect(turn.assistantMessages.map(\.outputText) == [["let me look"]])
    #expect(turn.reasoning.map(\.encryptedContent) == ["ENC"])
    #expect(turn.toolCalls == calls)
  }

  /// Reasoning material is opaque bytes to everything but this codec, so the round-trip has to
  /// survive the text a naive encoder would mangle — slashes, quotes, and non-ASCII alike.
  @Test func roundTripPreservesAwkwardContent() throws {
    // given
    let items = ChatGPTReplayItems(
      reasoning: [
        ChatGPTReasoningItem(
          encryptedContent: "gAAAAA/+w==",
          summary: ["a \"quoted\" thought", "emoji 🧠 and ünïcode"]
        )
      ],
      assistantMessages: [
        ChatGPTAssistantMessageItem(outputText: ["line one\nline two", "path/to/thing"])
      ]
    )

    // when
    let state = try Self.codec().encodeResponseState(
      items: items,
      identity: Self.identity(epoch: Self.epoch)
    )
    let decoded = try #require(Self.decodeItems(state))

    // then
    #expect(decoded.reasoning == items.reasoning)
    #expect(decoded.assistantMessages == items.assistantMessages)
  }

  // MARK: - Caps

  /// The per-state cap, from both sides. A state exactly at the cap is kept, so the drop below is a
  /// verdict on the size rather than on the codec refusing everything large.
  @Test func perStateCapAdmitsTheBoundaryAndDropsTheByteAbove() throws {
    // given
    let identity = Self.identity(epoch: Self.epoch)
    let atCap = try Self.state(
      canonicalBytes: ChatGPTProviderStateCodec.maximumStateBytes,
      identity: identity
    )
    let overCap = try Self.state(
      canonicalBytes: ChatGPTProviderStateCodec.maximumStateBytes + 1,
      identity: identity
    )

    // when
    let admitted = Self.codec().decodeCompatibleHistory(
      messages: [ChatMessage(role: .assistant, content: "a", providerState: atCap)],
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )
    let refused = Self.codec().decodeCompatibleHistory(
      messages: [ChatMessage(role: .assistant, content: "a", providerState: overCap)],
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(admitted.turns.keys.sorted() == [0])
    #expect(admitted.drops.isEmpty)
    #expect(refused.turns.isEmpty)
    #expect(refused.drops.oversized == 1)
  }

  /// The mirror of the drop above, and the write side's half of the codec's one rule. By the time a
  /// response is stamped its text and its tool calls have already arrived, so reasoning too large to
  /// store costs the turn its replay continuity and nothing else: the epoch is still written, and a
  /// restart still reads the stamp back as the live generation.
  @Test func encodingOverThePerStateCapKeepsTheEpochAndDropsTheReasoning() throws {
    // given
    let oversized = ChatGPTReplayItems(
      reasoning: [
        ChatGPTReasoningItem(
          encryptedContent: String(
            repeating: "a",
            count: ChatGPTProviderStateCodec.maximumStateBytes + 1
          )
        )
      ],
      assistantMessages: [ChatGPTAssistantMessageItem(outputText: ["the answer"])]
    )

    // when
    let stamp = try Self.codec().encodeResponseState(
      items: oversized,
      identity: Self.identity(epoch: Self.epoch)
    )
    let reloaded = Self.codec().decodeCompatibleHistory(
      messages: [ChatMessage(role: .assistant, content: "the answer", providerState: stamp)],
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(stamp.issuer == Self.goldenIssuer)
    #expect(stamp.payload.count <= ChatGPTProviderStateCodec.maximumStateBytes)
    #expect(Self.decodeItems(stamp) == ChatGPTReplayItems())
    #expect(reloaded.identity.epoch == Self.epoch)
    #expect(reloaded.turns[0]?.reasoning.isEmpty == true)
    #expect(reloaded.drops.isEmpty)
  }

  /// Four states summing to exactly the aggregate cap all travel. This is the positive half that
  /// stops the eviction test below from passing on a codec that simply drops the oldest always.
  @Test func aggregateCapAdmitsHistoryExactlyAtTheBoundary() throws {
    // given
    let identity = Self.identity(epoch: Self.epoch)
    let quarter = ChatGPTProviderStateCodec.maximumAggregateStateBytes / 4
    let history = try (0..<4).map { index in
      ChatMessage(
        role: .assistant,
        content: "turn \(index)",
        providerState: try Self.state(canonicalBytes: quarter, identity: identity)
      )
    }

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.turns.keys.sorted() == [0, 1, 2, 3])
    #expect(selection.drops.isEmpty)
  }

  /// One byte over the aggregate and the oldest optional state is the one that goes — newest-first
  /// selection, chronological emission, and the ordinary turn left entirely intact underneath.
  @Test func oldestStatesAreEvictedFirstAtTheAggregateCap() throws {
    // given
    let identity = Self.identity(epoch: Self.epoch)
    let quarter = ChatGPTProviderStateCodec.maximumAggregateStateBytes / 4
    let calls = [ToolCall(id: "call_1", name: "clock", argumentsJSON: "{}")]
    let history = try (0..<5).map { index in
      ChatMessage(
        role: .assistant,
        content: "turn \(index)",
        toolCalls: index == 0 ? calls : [],
        providerState: try Self.state(canonicalBytes: quarter, identity: identity)
      )
    }

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.turns.keys.sorted() == [1, 2, 3, 4])
    #expect(selection.drops.budgetEvicted == 1)
    // The evicted turn keeps its text and its call; only the reasoning it carried is unavailable.
    #expect(selection.turns[0] == nil)
    #expect(history[0].content.text == "turn 0")
    #expect(history[0].toolCalls == calls)
  }

  /// Eviction counts every state it walks away from, not just the first one over the line. The
  /// per-state cap is what bounds each one, so it takes four to fill the aggregate and the three
  /// oldest of seven are the ones left behind.
  @Test func everyStatePastTheAggregateCapIsCounted() throws {
    // given
    let identity = Self.identity(epoch: Self.epoch)
    let history = try (0..<7).map { index in
      ChatMessage(
        role: .assistant,
        content: "turn \(index)",
        providerState: try Self.state(
          canonicalBytes: ChatGPTProviderStateCodec.maximumStateBytes,
          identity: identity
        )
      )
    }

    // when
    let selection = Self.codec().decodeCompatibleHistory(
      messages: history,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(selection.turns.keys.sorted() == [3, 4, 5, 6])
    #expect(selection.drops.budgetEvicted == 3)
    #expect(selection.drops.oversized == 0)
  }

  // MARK: - Epoch recovery

  /// A recovery walks away from the epoch that poisoned the turn rather than from the session.
  @Test func recoveryIdentityMintsANewEpoch() {
    // given
    let minted = Self.fixedUUID("88888888-8888-4888-8888-888888888888")
    let codec = Self.codec(newEpoch: minted)

    // when
    let identity = codec.stateFreeRecoveryIdentity(
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(identity.epoch == minted)
    #expect(identity.credentialProfileHash == "11e594f481958c10e3015d0bf0447a22")
    #expect(identity.wireModelHash == "b0a9d642d12f553129c39513f7ce2605")
    #expect(identity.epoch != Self.epoch)
  }

  /// What makes the poison stay dead. The recovered response carried no reasoning, so the only thing
  /// its stamp can say is the new epoch — and it must still be written, because that stamp is the
  /// entire record a restart derives the epoch from. Without it, the newest compatible state in
  /// history is the poisoned one again and the recovery is undone on reload.
  @Test func emptyRecoveryStampSurvivesARestartAndBuriesThePoison() throws {
    // given
    let poisonedEpoch = Self.epoch
    let recoveredEpoch = Self.fixedUUID("88888888-8888-4888-8888-888888888888")
    let codec = Self.codec(newEpoch: recoveredEpoch)
    let recovery = codec.stateFreeRecoveryIdentity(
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // when
    let stamp = try codec.encodeResponseState(items: ChatGPTReplayItems(), identity: recovery)
    // The history a restart reads back: the poisoned turn, then the recovered turn's empty stamp.
    let reloaded = [
      ChatMessage(
        role: .assistant,
        content: "poisoned",
        providerState: try Self.state(
          reasoning: "POISON",
          identity: Self.identity(epoch: poisonedEpoch)
        )
      ),
      ChatMessage(role: .user, content: "retry"),
      ChatMessage(role: .assistant, content: "recovered", providerState: stamp),
    ]
    let selection = Self.codec(newEpoch: Self.epoch).decodeCompatibleHistory(
      messages: reloaded,
      profileID: Self.profileID,
      wireModel: Self.wireModel
    )

    // then
    #expect(stamp.payload.isEmpty == false)
    #expect(selection.identity.epoch == recoveredEpoch)
    #expect(selection.turns.keys.sorted() == [2])
    #expect(selection.turns[2]?.reasoning.isEmpty == true)
    #expect(selection.drops.staleEpoch == 1)
  }
}

// MARK: - Diagnostic Recorder

/// Captures what the codec reports. A class rather than a captured var because the callback is
/// `@Sendable`, and the codec makes no promise about which thread it fires on.
// MARK: - Fixtures

extension ChatGPTProviderStateCodecTests {
  /// A fixture literal, read once. A failure here is a typo in the constant below rather than a
  /// condition any test is meant to observe, so it stops the run where the typo is instead of
  /// travelling through every signature as an optional nothing ever expects to be empty.
  fileprivate static func fixedUUID(_ text: String) -> UUID {
    guard let uuid = UUID(uuidString: text) else {
      preconditionFailure("fixture is not a UUID: \(text)")
    }
    return uuid
  }

  /// The payload as text. The failable initializer is the honest one: everything asserted here was
  /// written by the encoder as UTF-8 JSON, so bytes that will not convert are a real failure rather
  /// than something to paper over with replacement characters.
  fileprivate static func rendered(_ state: ProviderExchangeState) throws -> String {
    try #require(String(bytes: state.payload, encoding: .utf8))
  }

  fileprivate static let profileID = fixedUUID("00000000-0000-4000-8000-000000000001")
  fileprivate static let reloginProfileID = fixedUUID("00000000-0000-4000-8000-000000000002")
  fileprivate static let wireModel = "gpt-5"
  fileprivate static let epoch = fixedUUID("11111111-1111-4111-8111-111111111111")
  fileprivate static let otherEpoch = fixedUUID("22222222-2222-4222-8222-222222222222")

  /// Derived outside this process with `shasum -a 256` over the lowercase profile UUID and the wire
  /// model, first sixteen bytes apiece.
  fileprivate static let goldenIssuer =
    "openai-chatgpt-responses-v1:11e594f481958c10e3015d0bf0447a22:"
    + "b0a9d642d12f553129c39513f7ce2605:11111111-1111-4111-8111-111111111111"

  fileprivate static func identity(epoch: UUID) -> ChatGPTReplayIdentity {
    ChatGPTReplayIdentity(profileID: profileID, wireModel: wireModel, epoch: epoch)
  }

  fileprivate static func codec(
    newEpoch: UUID = fixedUUID("00000000-0000-4000-8000-00000000ffff")
  ) -> ChatGPTProviderStateCodec {
    ChatGPTProviderStateCodec(newEpoch: {
      newEpoch
    })
  }

  fileprivate static func state(
    reasoning: String,
    identity: ChatGPTReplayIdentity
  ) throws -> ProviderExchangeState {
    try codec().encodeResponseState(
      items: ChatGPTReplayItems(
        reasoning: [ChatGPTReasoningItem(encryptedContent: reasoning)],
        assistantMessages: [ChatGPTAssistantMessageItem(outputText: ["hi"])]
      ),
      identity: identity
    )
  }

  /// A state whose canonical encoding weighs exactly `canonicalBytes`. The padding is ASCII that
  /// JSON never escapes, so a byte of content is a byte of payload and the boundary tests can name
  /// the cap rather than approach it.
  fileprivate static func state(
    canonicalBytes: Int,
    identity: ChatGPTReplayIdentity
  ) throws -> ProviderExchangeState {
    let empty = try codec().encodeResponseState(
      items: ChatGPTReplayItems(reasoning: [ChatGPTReasoningItem(encryptedContent: "")]),
      identity: identity
    )
    let padding = canonicalBytes - empty.payload.count
    #expect(padding >= 0)
    let items = ChatGPTReplayItems(
      reasoning: [ChatGPTReasoningItem(encryptedContent: String(repeating: "a", count: padding))]
    )
    guard let json = CanonicalJSON.encode(ChatGPTDurableReplayPayload(items)) else {
      throw ProviderError.terminal(status: nil, message: "fixture could not be encoded")
    }
    let state = ProviderExchangeState(issuer: identity.issuer, payload: Data(json.utf8))
    #expect(state.payload.count == canonicalBytes)
    return state
  }

  fileprivate static func decodeItems(_ state: ProviderExchangeState) -> ChatGPTReplayItems? {
    ChatGPTDurableReplayPayload.decode(state.payload)
  }
}
