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

/// The numeric-ID default-deny boundary. `allowUnlistedPrivateUsers` exists only for the isolated
/// conference profile, whose composition exposes no personal/general-purpose tools or memory.
public struct AccessControl: Sendable {
  private let allowlist: any AllowlistStore
  private let groupChats: Set<Int64>
  private let allowUnlistedPrivateUsers: Bool

  public init(
    allowlist: any AllowlistStore,
    groupChats: Set<Int64>,
    allowUnlistedPrivateUsers: Bool = false
  ) {
    self.allowlist = allowlist
    self.groupChats = groupChats
    self.allowUnlistedPrivateUsers = allowUnlistedPrivateUsers
  }

  public func isAllowed(userId: Int64) -> Bool {
    if allowUnlistedPrivateUsers {
      return true
    }
    do {
      return try allowlist.allowlistContains(userId: userId)
    } catch {
      return false
    }
  }

  /// Conference participants use private chats only: a group topic shares conversational history
  /// between senders. Ordinary mode retains its owner-DM and configured-group behavior.
  public func decide(chatKind: ChatKind, chatId: Int64, userId: Int64) -> AccessDecision {
    switch chatKind {
    case .private:
      return isAllowed(userId: userId) ? .allowed(.direct) : .denied(.privateStranger)
    case .group, .supergroup:
      guard !allowUnlistedPrivateUsers else {
        return .denied(.unlistedChat)
      }
      return groupChats.contains(chatId) ? .allowed(.group) : .denied(.unlistedChat)
    case .channel, .other:
      return .denied(.unlistedChat)
    }
  }
}
