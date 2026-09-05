import ClawCore
import Foundation

/// A parked command effect awaiting the owner's yes/no (single slot per session).
public enum CommandConfirmation: Sendable, Equatable {
  case rememberWrite(MemoryWriteRequest)
  case deleteItem(id: Int64)
  case scheduleArm(ValidatedSchedule)
  case learningReset(jobId: Int64)
}

public actor PendingConfirmationRegistry {
  private var entries: [Int64: CommandConfirmation] = [:]

  public init() {}

  public func park(_ entry: CommandConfirmation, sessionId: Int64) {
    entries[sessionId] = entry
  }

  public func pending(sessionId: Int64) -> CommandConfirmation? {
    entries[sessionId]
  }

  public func clear(sessionId: Int64) {
    entries[sessionId] = nil
  }
}

enum ConfirmationReply: Sendable, Equatable {
  case confirm
  case cancel
  case other

  static func parse(_ text: String) -> ConfirmationReply {
    switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "yes", "y":
      .confirm
    case "no", "n", "cancel":
      .cancel
    default:
      .other
    }
  }
}
