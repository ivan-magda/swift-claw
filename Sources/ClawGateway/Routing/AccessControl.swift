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

/// The numeric-ID default-deny boundary. The conference profile serves configured groups only.
public struct AccessControl: Sendable {
  private let allowlist: any AllowlistStore
  private let groupChats: Set<Int64>
  private let conferenceProfile: Bool

  public init(
    allowlist: any AllowlistStore,
    groupChats: Set<Int64>,
    conferenceProfile: Bool = false
  ) {
    self.allowlist = allowlist
    self.groupChats = groupChats
    self.conferenceProfile = conferenceProfile
  }

  public func isAllowed(userId: Int64) -> Bool {
    if conferenceProfile {
      return false
    }
    do {
      return try allowlist.allowlistContains(userId: userId)
    } catch {
      return false
    }
  }

  public func decide(chatKind: ChatKind, chatId: Int64, userId: Int64) -> AccessDecision {
    switch chatKind {
    case .private:
      guard !conferenceProfile else {
        return .denied(.unlistedChat)
      }
      return isAllowed(userId: userId) ? .allowed(.direct) : .denied(.privateStranger)
    case .group, .supergroup:
      return groupChats.contains(chatId) ? .allowed(.group) : .denied(.unlistedChat)
    case .channel, .other:
      return .denied(.unlistedChat)
    }
  }
}
