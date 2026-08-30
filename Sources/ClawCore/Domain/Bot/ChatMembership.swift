/// The bot's own standing in a chat, as Bot API `ChatMember.status` spells it.
///
/// `other` keeps an unrecognized status intact rather than folding it into a known case, and counts
/// as present: a status this build has never seen must never be read as the bot having been thrown
/// out, because that reading would be printed to an operator as fact.
public enum ChatMembershipStatus: Sendable, Equatable {
  case creator
  case administrator
  case member
  case restricted
  case left
  case kicked
  case other(String)

  public init(apiValue: String) {
    switch apiValue {
    case "creator": self = .creator
    case "administrator": self = .administrator
    case "member": self = .member
    case "restricted": self = .restricted
    case "left": self = .left
    case "kicked": self = .kicked
    default: self = .other(apiValue)
    }
  }

  /// The Bot API `status` string this case came from.
  public var apiValue: String {
    switch self {
    case .creator: "creator"
    case .administrator: "administrator"
    case .member: "member"
    case .restricted: "restricted"
    case .left: "left"
    case .kicked: "kicked"
    case .other(let value): value
    }
  }

  /// Whether the bot is in the chat at all. A restricted member still is — the restriction shapes
  /// what it may send, not whether it is there.
  public var isPresent: Bool {
    switch self {
    case .left, .kicked: false
    case .creator, .administrator, .member, .restricted, .other: true
    }
  }
}

/// What a membership update did to the bot, in the only terms an operator acts on.
public enum ChatMembershipChange: Sendable, Equatable {
  case added
  case removed
  /// Still in the chat, with different rights — the promotion that lifts privacy mode lands here.
  case updated
  case unchanged
}

/// Bot API `ChatMemberUpdated` for the bot itself, wire-agnostic like `RawUpdate`.
///
/// Observed, never acted on: it carries no message, so it reaches no session and grants no access.
/// Its whole purpose is the operator-facing log — being added to a room is the only moment the
/// chat id that would have to go into `CLAW_GROUP_CHATS` is announced.
public struct RawChatMemberUpdate: Sendable, Equatable {
  public let chatId: Int64
  public let chatKind: ChatKind
  public let chatTitle: String?
  /// Who made the change. Absent when Telegram reports one with no acting user.
  public let actorUserId: Int64?
  public let actorDisplayName: String?
  public let oldStatus: ChatMembershipStatus
  public let newStatus: ChatMembershipStatus

  public init(
    chatId: Int64,
    chatKind: ChatKind,
    chatTitle: String? = nil,
    actorUserId: Int64? = nil,
    actorDisplayName: String? = nil,
    oldStatus: ChatMembershipStatus,
    newStatus: ChatMembershipStatus
  ) {
    self.chatId = chatId
    self.chatKind = chatKind
    self.chatTitle = chatTitle
    self.actorUserId = actorUserId
    self.actorDisplayName = actorDisplayName
    self.oldStatus = oldStatus
    self.newStatus = newStatus
  }

  public var change: ChatMembershipChange {
    switch (oldStatus.isPresent, newStatus.isPresent) {
    case (false, true): .added
    case (true, false): .removed
    case (true, true), (false, false): oldStatus == newStatus ? .unchanged : sameSideChange
    }
  }

  /// Two statuses on the same side of the door: a rights change while in the chat, and nothing
  /// worth a distinct word while out of it (left → kicked is still gone).
  private var sameSideChange: ChatMembershipChange {
    newStatus.isPresent ? .updated : .unchanged
  }
}
