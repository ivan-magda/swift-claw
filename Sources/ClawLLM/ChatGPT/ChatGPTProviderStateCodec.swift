import ClawCore
import Foundation

// MARK: - Replay Origin

/// Everything an identity is except its epoch: the origin a state must have come from to be
/// replayable here at all.
///
/// It exists as its own type because a request derives it once and then asks it about every message
/// in the history. Folding it back into `ChatGPTReplayIdentity` would mean inventing an epoch for a
/// question the epoch has no part in.
struct ChatGPTReplayOrigin: Sendable, Equatable {
  let credentialProfileHash: String
  let wireModelHash: String

  init(profileID: UUID, wireModel: String) {
    self.credentialProfileHash = Self.hash(profileID.uuidString.lowercased())
    self.wireModelHash = Self.hash(wireModel)
  }

  func identity(epoch: UUID) -> ChatGPTReplayIdentity {
    ChatGPTReplayIdentity(origin: self, epoch: epoch)
  }

  /// Whether a state minted under `identity` came from here. The epoch is a separate question —
  /// which generation is live — so a caller that needs both asks both.
  func matches(_ identity: ChatGPTReplayIdentity) -> Bool {
    identity.credentialProfileHash == credentialProfileHash
      && identity.wireModelHash == wireModelHash
  }
}

// MARK: - Origin Hashing

private extension ChatGPTReplayOrigin {
  static func hash(_ text: String) -> String {
    String(SHA256Digest.hex(Data(text.utf8)).prefix(ChatGPTReplayIdentity.hashByteCount * 2))
  }
}

// MARK: - Replay Identity

/// What binds a piece of replay state to the origin that can actually use it.
///
/// The credential-profile hash is derived from the locally generated profile ID and from nothing
/// else — never from JWT metadata, an account claim, or the access token, all of which move under a
/// refresh that changes nothing about whose conversation this is. Re-login mints a new profile ID,
/// so it invalidates every prior state; a refresh leaves the ID alone and keeps them replayable.
/// That asymmetry is the whole point of the choice, and it is why this type takes a `UUID` rather
/// than a credential it could be tempted to read.
///
/// The rendered issuer is a logical identity, not a URL and not a lookup key: it carries three
/// digests and a version, so nothing about the owner's profile, account, or model survives into a
/// value the database keeps beside every assistant turn.
struct ChatGPTReplayIdentity: Sendable, Equatable {
  /// Bumped when the payload shape or the identity's own construction changes. Every state minted
  /// under a prior version reads as foreign, which is the migration: state is a cache of reasoning
  /// continuity, so dropping it costs a session its reasoning replay and nothing more.
  static let providerVersion = "openai-chatgpt-responses-v1"

  /// Half a SHA-256, rendered as 32 hex characters. Wide enough that two profiles or two models
  /// colliding is not a practical concern, and short enough to keep the issuer readable in a row.
  static let hashByteCount = 16

  let credentialProfileHash: String
  let wireModelHash: String
  let epoch: UUID

  var issuer: String {
    [
      Self.providerVersion,
      credentialProfileHash,
      wireModelHash,
      epoch.uuidString.lowercased(),
    ].joined(separator: ":")
  }

  init(profileID: UUID, wireModel: String, epoch: UUID) {
    self.init(origin: ChatGPTReplayOrigin(profileID: profileID, wireModel: wireModel), epoch: epoch)
  }

  init(origin: ChatGPTReplayOrigin, epoch: UUID) {
    self.credentialProfileHash = origin.credentialProfileHash
    self.wireModelHash = origin.wireModelHash
    self.epoch = epoch
  }

  /// Reads back an issuer this codec minted, or nil for anything else — another provider, another
  /// version of this one, or a value that has been damaged since it was written. A nil here is never
  /// an error: it means the state belongs to someone else and is simply not ours to replay.
  init?(issuer: String) {
    let fields = issuer.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 4, fields[0] == Self.providerVersion else {
      return nil
    }
    guard
      Self.isCanonicalHash(fields[1]),
      Self.isCanonicalHash(fields[2]),
      let epoch = Self.canonicalEpoch(fields[3])
    else {
      return nil
    }
    self.credentialProfileHash = String(fields[1])
    self.wireModelHash = String(fields[2])
    self.epoch = epoch
  }
}

// MARK: - Identity Rendering

private extension ChatGPTReplayIdentity {
  /// Only the exact rendering this type produces is accepted. Uppercase hex would digest the same
  /// bytes but is not what any live writer emits, so treating it as ours would mean accepting an
  /// issuer that nothing here could have written.
  static func isCanonicalHash(_ field: Substring) -> Bool {
    field.count == hashByteCount * 2
      && field.allSatisfy { character in
        character.isHexDigit && character.isUppercase == false
      }
  }

  static func canonicalEpoch(_ field: Substring) -> UUID? {
    guard let epoch = UUID(uuidString: String(field)) else {
      return nil
    }
    // `UUID(uuidString:)` is case-insensitive, so the round-trip is what actually pins the canonical
    // lowercase form the issuer is specified in.
    return epoch.uuidString.lowercased() == field ? epoch : nil
  }
}

// MARK: - Replay Items

/// One reasoning item as it is persisted. No server item ID is carried: `store: false` means no
/// later request can resolve one, and the SSE parser already drops it upstream, so there is nothing
/// here for a handle to point at.
struct ChatGPTReasoningItem: Sendable, Equatable {
  let encryptedContent: String
  let summary: [String]

  init(encryptedContent: String, summary: [String] = []) {
    self.encryptedContent = encryptedContent
    self.summary = summary
  }
}

/// One assistant message item as it is persisted, carrying the status and phase the route stated so
/// the replayed item reads back as the turn the backend produced rather than a reconstruction of it.
struct ChatGPTAssistantMessageItem: Sendable, Equatable {
  let role: String
  let status: String
  let phase: String?
  let outputText: [String]

  init(
    role: String = "assistant",
    status: String = "completed",
    phase: String? = nil,
    outputText: [String]
  ) {
    self.role = role
    self.status = status
    self.phase = phase
    self.outputText = outputText
  }
}

/// The whole of what a turn's opaque state holds: two arrays and no third.
///
/// Function calls are deliberately absent. They live in `ChatMessage.toolCalls` and are synthesized
/// on every request, so a state dropped for corruption or for budget costs the turn its reasoning
/// continuity and never its tool proposal.
struct ChatGPTReplayItems: Sendable, Equatable {
  let reasoning: [ChatGPTReasoningItem]
  let assistantMessages: [ChatGPTAssistantMessageItem]

  init(
    reasoning: [ChatGPTReasoningItem] = [],
    assistantMessages: [ChatGPTAssistantMessageItem] = []
  ) {
    self.reasoning = reasoning
    self.assistantMessages = assistantMessages
  }
}

/// What one history message contributes to a request once its state has been read back.
///
/// The calls are copied from the message rather than from the state, which is what makes the
/// substitution rule structural: replayed material stands in for the assistant text a turn would
/// otherwise synthesize, and the calls travel beside it whatever happened to the state.
struct ChatGPTReplayTurn: Sendable, Equatable {
  let reasoning: [ChatGPTReasoningItem]
  let assistantMessages: [ChatGPTAssistantMessageItem]
  let toolCalls: [ToolCall]

  /// Whether this turn carries anything that stands in for the synthesized assistant text. An
  /// over-cap eviction stamps a turn's state empty, leaving reasoning and messages both blank;
  /// replaying that turn would emit no assistant text and drop the answer the ordinary message still
  /// holds, so the encoder falls back to normal encoding when this is false.
  var hasReplayMaterial: Bool {
    reasoning.isEmpty == false || assistantMessages.isEmpty == false
  }
}

// MARK: - Diagnostics

/// Why replay state was left behind, counted and nothing more.
///
/// Every field is an `Int` by construction. A warning about state that quoted the state — or the
/// issuer, which names the profile's own digest — would be the leak it is warning about, so the type
/// gives a reporter nothing to spill even if one tried.
struct ChatGPTReplayDrops: Sendable, Equatable {
  /// Another provider, another version, or an issuer too damaged to read as ours.
  var foreign = 0
  /// Ours, but from a generation a recovery has already walked away from.
  var staleEpoch = 0
  /// Ours and current, but the payload is not the shape this codec writes. The store keeps opaque
  /// bytes and cannot judge them, so this is the only place the damage is visible.
  var malformed = 0
  var oversized = 0
  /// Sound state omitted so the request fits its aggregate budget.
  var budgetEvicted = 0

  var total: Int {
    foreign + staleEpoch + malformed + oversized + budgetEvicted
  }

  var isEmpty: Bool {
    total == 0
  }
}

/// What a request may replay, and what it could not.
struct ChatGPTReplaySelection: Sendable, Equatable {
  /// The identity every response this request produces must be stamped with — the epoch derived from
  /// the newest compatible state, or a fresh one when the history holds none.
  let identity: ChatGPTReplayIdentity

  /// Replayed material keyed by its index in the messages handed in, so the caller emits it in the
  /// history's own chronological order. An index that is absent simply synthesizes its text.
  let turns: [Int: ChatGPTReplayTurn]

  let drops: ChatGPTReplayDrops
}

// MARK: - Codec

/// Reads replay state back out of a history and writes it into a response.
///
/// It is pure: no transport, no credential, no clock. What it owns is the judgment of which state is
/// still ours, how much of it a request can afford, and which epoch the next response is stamped
/// with. The attempt engine that retries a poisoned turn and the provider that wires this to a
/// request are elsewhere; this only has to be able to tell them the identity to use.
struct ChatGPTProviderStateCodec: Sendable {
  static let maximumStateBytes = LLMReplayStateBounds.maximumStateBytes
  static let maximumAggregateStateBytes = LLMReplayStateBounds.maximumAggregateBytes

  private let newEpoch: @Sendable () -> UUID
  private let reportDrops: @Sendable (ChatGPTReplayDrops) -> Void

  /// The epoch generator is injected so a test can name the epoch a history derives instead of
  /// matching against randomness. The reporter is a callback rather than a logger because this type
  /// has no business choosing a logging backend, and because a caller that wants the counts on a
  /// metric rather than in a line should not have to parse one.
  init(
    newEpoch: @escaping @Sendable () -> UUID = {
      UUID()
    },
    reportDrops: @escaping @Sendable (ChatGPTReplayDrops) -> Void = { _ in
    }
  ) {
    self.newEpoch = newEpoch
    self.reportDrops = reportDrops
  }

  /// Selects the replay material a request may carry, and the identity its response is stamped with.
  ///
  /// Nothing here can fail a turn. State that is foreign, damaged, too large, or simply unaffordable
  /// is left behind and counted; the conversation continues on its text and its tool calls, which
  /// are never this method's to drop.
  func decodeCompatibleHistory(
    messages: [ChatMessage],
    profileID: UUID,
    wireModel: String
  ) -> ChatGPTReplaySelection {
    var drops = ChatGPTReplayDrops()
    let origin = ChatGPTReplayOrigin(profileID: profileID, wireModel: wireModel)
    let candidates = Self.compatibleCandidates(
      in: messages,
      origin: origin,
      drops: &drops
    )

    // The newest state that actually decoded is what names the live epoch. A damaged or foreign
    // newest state has already been discarded above, so it cannot drag the session onto a generation
    // that no sound state belongs to.
    guard let newest = candidates.last else {
      report(drops)
      return ChatGPTReplaySelection(
        identity: origin.identity(epoch: newEpoch()),
        turns: [:],
        drops: drops
      )
    }

    let live = candidates.filter { candidate in
      candidate.epoch == newest.epoch
    }
    drops.staleEpoch += candidates.count - live.count

    let selected = Self.affordable(live, drops: &drops)
    var turns: [Int: ChatGPTReplayTurn] = [:]
    for candidate in selected {
      turns[candidate.index] = ChatGPTReplayTurn(
        reasoning: candidate.items.reasoning,
        assistantMessages: candidate.items.assistantMessages,
        toolCalls: messages[candidate.index].toolCalls
      )
    }

    report(drops)
    return ChatGPTReplaySelection(
      identity: origin.identity(epoch: newest.epoch),
      turns: turns,
      drops: drops
    )
  }

  /// Stamps a response's reasoning material with the identity that can replay it.
  ///
  /// State loss degrades continuity, never the turn — the same rule the read side keeps. By the time
  /// this runs the text and the tool calls have already arrived and the turn has succeeded, so
  /// reasoning too large to store is stamped as the empty payload rather than refused: the epoch
  /// survives, and only the replay continuity is lost. The throw is left for material that cannot be
  /// rendered at all.
  ///
  /// Empty items are still a state. A recovered turn that produced no reasoning has only its epoch
  /// to say, and that stamp is the entire record a restart derives the epoch from: without it the
  /// newest compatible state in history is the poisoned one again, and the recovery is undone on
  /// reload. So this writes the empty payload rather than returning nothing.
  func encodeResponseState(
    items: ChatGPTReplayItems,
    identity: ChatGPTReplayIdentity
  ) throws -> ProviderExchangeState {
    let payload = try Self.canonicalPayload(items)
    guard payload.count <= Self.maximumStateBytes else {
      return ProviderExchangeState(
        issuer: identity.issuer,
        payload: try Self.canonicalPayload(ChatGPTReplayItems())
      )
    }
    return ProviderExchangeState(issuer: identity.issuer, payload: payload)
  }

  /// The identity a state-free retry stamps its success with, on a generation no prior state shares.
  func stateFreeRecoveryIdentity(profileID: UUID, wireModel: String) -> ChatGPTReplayIdentity {
    ChatGPTReplayIdentity(profileID: profileID, wireModel: wireModel, epoch: newEpoch())
  }
}

// MARK: - Selection

private extension ChatGPTProviderStateCodec {
  static let unencodableState = ProviderError.terminal(
    status: nil,
    message: "the ChatGPT reply produced replay state that could not be encoded"
  )

  /// The canonical bytes of a payload. Size is not this function's question — only whether the
  /// material renders at all, which is the one failure the write side has no lenient answer to.
  static func canonicalPayload(_ items: ChatGPTReplayItems) throws -> Data {
    guard let json = CanonicalJSON.encode(ChatGPTDurableReplayPayload(items)) else {
      throw unencodableState
    }
    return Data(json.utf8)
  }

  /// One history state that survived every check, with the weight it will actually cost the request.
  struct Candidate {
    let index: Int
    let epoch: UUID
    let items: ChatGPTReplayItems
    let bytes: Int
  }

  /// Every state of this origin that reads back, in the history's own order. The four issuer fields
  /// are checked together — version, profile, model, and a well-formed epoch — before the payload is
  /// touched at all, so a foreign blob is never parsed and never sized.
  static func compatibleCandidates(
    in messages: [ChatMessage],
    origin: ChatGPTReplayOrigin,
    drops: inout ChatGPTReplayDrops
  ) -> [Candidate] {
    var candidates: [Candidate] = []
    for (index, message) in messages.enumerated() {
      guard let state = message.providerState else {
        continue
      }
      guard
        let identity = ChatGPTReplayIdentity(issuer: state.issuer),
        origin.matches(identity)
      else {
        drops.foreign += 1
        continue
      }
      // Sized before it is parsed: a payload this large is not decoded merely to learn it is too
      // large to send.
      guard state.payload.count <= maximumStateBytes else {
        drops.oversized += 1
        continue
      }
      guard
        let items = ChatGPTDurableReplayPayload.decode(state.payload),
        let json = CanonicalJSON.encode(ChatGPTDurableReplayPayload(items))
      else {
        drops.malformed += 1
        continue
      }
      // The budget is spent on what the request will carry, which is this re-encoding rather than
      // whatever an older writer happened to store.
      let bytes = json.utf8.count
      guard bytes <= maximumStateBytes else {
        drops.oversized += 1
        continue
      }
      candidates.append(Candidate(index: index, epoch: identity.epoch, items: items, bytes: bytes))
    }
    return candidates
  }

  /// The newest run of states that fits the aggregate budget.
  ///
  /// Walking newest-first and stopping at the first state that would cross the cap is what makes the
  /// omission oldest-first: continuing past it could admit a small ancient state over a large recent
  /// one, which is the opposite of the rule. The result is returned chronologically.
  static func affordable(
    _ candidates: [Candidate],
    drops: inout ChatGPTReplayDrops
  ) -> [Candidate] {
    var selected: [Candidate] = []
    var total = 0
    for (offset, candidate) in candidates.reversed().enumerated() {
      // Saturating rather than trapping: each state is already under the per-state cap, so a total
      // that could overflow has certainly passed the aggregate one — clamping refuses the state,
      // which is the safe direction.
      let running = SaturatingArithmetic.sum(total, candidate.bytes)
      guard running <= maximumAggregateStateBytes else {
        drops.budgetEvicted += candidates.count - offset
        break
      }
      total = running
      selected.append(candidate)
    }
    return selected.reversed()
  }

  func report(_ drops: ChatGPTReplayDrops) {
    guard drops.isEmpty == false else {
      return
    }
    reportDrops(drops)
  }
}

// MARK: - Durable Payload

/// The on-disk shape of replay state.
///
/// It is kept apart from the wire request types on purpose. This one is durable — rows written today
/// are read back by a build shipped months from now — while the wire shape is whatever the route
/// currently wants. Folding them together would let a wire tweak silently reinterpret every stored
/// row, so the two are translated rather than shared, and this side changes only with the version in
/// the issuer.
struct ChatGPTDurableReplayPayload: Codable {
  let assistantMessages: [DurableAssistantMessage]
  let reasoning: [DurableReasoning]

  private enum CodingKeys: String, CodingKey {
    case assistantMessages = "assistant_messages"
    case reasoning
  }

  init(_ items: ChatGPTReplayItems) {
    self.assistantMessages = items.assistantMessages.map(DurableAssistantMessage.init)
    self.reasoning = items.reasoning.map(DurableReasoning.init)
  }

  /// Reads a stored payload back, or nil for bytes that are not this shape. The store holds opaque
  /// blobs and cannot tell a truncated row from a whole one, so this is where a clobbered state is
  /// actually caught — leniently, because a session that has lost its reasoning continuity is still
  /// a session, while one that threw here would be a turn the owner cannot take.
  static func decode(_ payload: Data) -> ChatGPTReplayItems? {
    guard let decoded = try? JSONDecoder().decode(Self.self, from: payload) else {
      return nil
    }
    return ChatGPTReplayItems(
      reasoning: decoded.reasoning.map { item in
        ChatGPTReasoningItem(encryptedContent: item.encryptedContent, summary: item.summary)
      },
      assistantMessages: decoded.assistantMessages.map { item in
        ChatGPTAssistantMessageItem(
          role: item.role,
          status: item.status,
          phase: item.phase,
          outputText: item.content.map(\.text)
        )
      }
    )
  }
}

struct DurableReasoning: Codable {
  static let type = "reasoning"

  let encryptedContent: String
  let summary: [String]

  private enum CodingKeys: String, CodingKey {
    case type
    case encryptedContent = "encrypted_content"
    case summary
  }

  init(_ item: ChatGPTReasoningItem) {
    self.encryptedContent = item.encryptedContent
    self.summary = item.summary
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .type) == Self.type else {
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "not a reasoning item"
      )
    }
    self.encryptedContent = try container.decode(String.self, forKey: .encryptedContent)
    // Absent means none, not damaged: the route omits the key entirely when it summarized nothing.
    self.summary = try container.decodeIfPresent([String].self, forKey: .summary) ?? []
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.type, forKey: .type)
    try container.encode(encryptedContent, forKey: .encryptedContent)
    try container.encode(summary, forKey: .summary)
  }
}

struct DurableAssistantMessage: Codable {
  static let type = "message"

  let role: String
  let status: String
  let phase: String?
  let content: [DurableContent]

  private enum CodingKeys: String, CodingKey {
    case type
    case role
    case status
    case phase
    case content
  }

  init(_ item: ChatGPTAssistantMessageItem) {
    self.role = item.role
    self.status = item.status
    self.phase = item.phase
    self.content = item.outputText.map(DurableContent.init)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .type) == Self.type else {
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "not a message item"
      )
    }
    self.role = try container.decode(String.self, forKey: .role)
    self.status = try container.decode(String.self, forKey: .status)
    self.phase = try container.decodeIfPresent(String.self, forKey: .phase)
    self.content = try container.decode([DurableContent].self, forKey: .content)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.type, forKey: .type)
    try container.encode(role, forKey: .role)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(phase, forKey: .phase)
    try container.encode(content, forKey: .content)
  }
}

struct DurableContent: Codable {
  static let type = "output_text"

  let text: String

  private enum CodingKeys: String, CodingKey {
    case type
    case text
  }

  init(_ text: String) {
    self.text = text
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .type) == Self.type else {
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "not an output-text part"
      )
    }
    self.text = try container.decode(String.self, forKey: .text)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.type, forKey: .type)
    try container.encode(text, forKey: .text)
  }
}
