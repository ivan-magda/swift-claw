/// Fresh membership proof for the requested group and user; uncertainty must never return true.
public protocol GroupMembershipChecking: Sendable {
  func isCurrentMember(chatID: Int64, userID: Int64) async throws -> Bool
}
