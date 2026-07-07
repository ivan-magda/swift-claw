import ClawCore
import Foundation

/// A parked command effect awaiting the owner's yes/no (single slot per session, §9).
public enum CommandConfirmation: Sendable, Equatable {
  case rememberWrite(MemoryWriteRequest)
  case deleteItem(id: Int64)
  case scheduleArm(ValidatedSchedule)
}

/// What the confirmation slot can hold. Command confirmations resolve through the yes/no
/// commit/cancel switch; a tool approval resolves by dispatching the reply as an ordinary
/// persisted turn (§14). Two types, so each resolver switch is exhaustive over only the cases
/// it can legally see — no "unreachable by ordering" arms.
public enum PendingConfirmation: Sendable, Equatable {
  case command(CommandConfirmation)
  case toolApproval(ToolApprovalRequest)
}

public actor PendingConfirmationRegistry {
  private var entries: [Int64: PendingConfirmation] = [:]

  public init() {}

  public func park(_ entry: PendingConfirmation, sessionId: Int64) {
    entries[sessionId] = entry
  }

  public func pending(sessionId: Int64) -> PendingConfirmation? {
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
