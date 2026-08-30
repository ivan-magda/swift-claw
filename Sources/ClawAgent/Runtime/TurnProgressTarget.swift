/// Where a turn's cosmetic progress signals land: the chat, the forum topic inside it, and the
/// draft identity the streaming bubble edits. Bundled so the round-trip helpers carry one value
/// instead of three positional ids that are only ever passed together.
struct TurnProgressTarget: Sendable {
  let chatId: Int64
  let threadId: Int64?
  let draftId: Int64
}
