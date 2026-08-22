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

extension ChatMode {
  /// The trust tier this conversation stores a line at.
  ///
  /// A DM keeps whatever tier the source earned, so a voice transcript still arrives untrusted and
  /// taints the session. A group line is always trusted: it is the room's own record, and recall
  /// only ever returns trusted rows, so storing an attendee's words any other way would make the
  /// topic's history unsearchable. The price is that a group session never arms taint.
  public func storedProvenance(of source: Provenance) -> Provenance {
    switch self {
    case .direct: source
    case .group: .trusted
    }
  }
}
