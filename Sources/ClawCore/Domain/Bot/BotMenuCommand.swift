/// A single entry in Telegram's native command picker shown when a user types `/`.
public struct BotMenuCommand: Sendable, Encodable {
  public let command: String
  public let description: String

  public init(command: String, description: String) {
    self.command = command
    self.description = description
  }
}
