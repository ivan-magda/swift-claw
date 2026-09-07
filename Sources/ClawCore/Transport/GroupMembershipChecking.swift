/// Fresh membership proof for the requested group and user; uncertainty must never return true.
public protocol GroupMembershipChecking: Sendable {
  func isCurrentMember(chatId: Int64, userId: Int64) async throws -> Bool
}
