import ClawCore

public struct GroupMembershipStub: GroupMembershipChecking {
  private let chatId: Int64
  private let memberUserIds: Set<Int64>
  private let fails: Bool

  public init(chatId: Int64, memberUserIds: Set<Int64>, fails: Bool = false) {
    self.chatId = chatId
    self.memberUserIds = memberUserIds
    self.fails = fails
  }

  public func isCurrentMember(chatId: Int64, userId: Int64) async throws -> Bool {
    if fails {
      throw TelegramError.transport("membership unavailable")
    }
    return chatId == self.chatId && memberUserIds.contains(userId)
  }
}
