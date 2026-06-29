public struct BotIdentity: Sendable, Equatable {
  public let id: Int64
  public let username: String?

  public init(id: Int64, username: String?) {
    self.id = id
    self.username = username
  }
}
