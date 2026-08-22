/// How a conversation is being served: one owner in a DM, or a shared topic in a group chat.
///
/// The mode is a property of the *conversation*, not of the chat kind on the wire: a group chat
/// that is not allowlisted is denied outright rather than downgraded, so only an accepted group
/// conversation is ever `.group`. Every downstream policy difference (no approvals, trusted
/// inbound, session-scoped recall) keys off this value, so it is derived once and carried.
public enum ChatMode: String, Sendable, Equatable, CaseIterable {
  case direct
  case group
}
