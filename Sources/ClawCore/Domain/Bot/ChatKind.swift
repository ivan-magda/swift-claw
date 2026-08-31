/// The kind of Telegram chat a message arrived in.
///
/// `other` keeps an unrecognized `type` string intact instead of folding it into a known case: a
/// group chat grants powers a DM does not, so a value this build has never seen must never widen
/// into `.private`.
public enum ChatKind: Sendable, Equatable {
  case `private`
  case group
  case supergroup
  case channel
  case other(String)

  public init(apiValue: String) {
    switch apiValue {
    case "private": self = .private
    case "group": self = .group
    case "supergroup": self = .supergroup
    case "channel": self = .channel
    default: self = .other(apiValue)
    }
  }

  /// The Bot API `chat.type` string this case came from.
  public var apiValue: String {
    switch self {
    case .private: "private"
    case .group: "group"
    case .supergroup: "supergroup"
    case .channel: "channel"
    case .other(let value): value
    }
  }
}
