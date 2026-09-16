import ClawCore

public struct GroupMembershipStub: GroupMembershipChecking {
  private let chatID: Int64
  private let memberUserIDs: Set<Int64>
  private let fails: Bool

  public init(chatID: Int64, memberUserIDs: Set<Int64>, fails: Bool = false) {
    self.chatID = chatID
    self.memberUserIDs = memberUserIDs
    self.fails = fails
  }

  public func isCurrentMember(chatID: Int64, userID: Int64) async throws -> Bool {
    if fails {
      throw TelegramError.transport("membership unavailable")
    }
    return chatID == self.chatID && memberUserIDs.contains(userID)
  }
}
