import ClawCore

/// Why an update was refused. The two reasons carry different obligations: a stranger in a DM is
/// answered so they can ask the owner for access, while an unlisted chat is answered with silence
/// so the bot never announces itself to a room it was added to uninvited.
public enum AccessDenial: Sendable, Equatable {
  case privateStranger
  case unlistedChat
}

/// The verdict for one inbound message: the mode it runs in, or the reason it was refused.
public enum AccessDecision: Sendable, Equatable {
  case allowed(ChatMode)
  case denied(AccessDenial)
}

/// The numeric-ID default-deny boundary. Fails CLOSED on any store error.
public struct AccessControl: Sendable {
  private let allowlist: any AllowlistStore
  private let groupChats: Set<Int64>

  public init(allowlist: any AllowlistStore, groupChats: Set<Int64> = []) {
    self.allowlist = allowlist
    self.groupChats = groupChats
  }

  public func isAllowed(userId: Int64) -> Bool {
    do {
      return try allowlist.allowlistContains(userId: userId)
    } catch {
      return false
    }
  }

  /// A DM is the owner's, keyed on the sender. A group is the season's, keyed on the chat: being
  /// in an allowlisted room is itself the membership proof, so no per-user check runs there and an
  /// attendee needs no allowlist entry. Every other shape — a channel, a chat kind this build has
  /// never seen — is refused, so a new Telegram surface can never inherit either grant.
  public func decide(chatKind: ChatKind, chatId: Int64, userId: Int64) -> AccessDecision {
    switch chatKind {
    case .private:
      return isAllowed(userId: userId) ? .allowed(.direct) : .denied(.privateStranger)
    case .group, .supergroup:
      return groupChats.contains(chatId) ? .allowed(.group) : .denied(.unlistedChat)
    case .channel, .other:
      return .denied(.unlistedChat)
    }
  }
}
