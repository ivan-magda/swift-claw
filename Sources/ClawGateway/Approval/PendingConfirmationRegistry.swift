import ClawCore
import Foundation

/// A parked command effect awaiting the owner's yes/no (single slot per session).
public enum CommandConfirmation: Sendable, Equatable {
  case rememberWrite(MemoryWriteRequest)
  case deleteItem(id: Int64)
  case scheduleArm(ValidatedSchedule)
}

/// What the confirmation slot can hold: only owner COMMAND confirmations (`/remember`,
/// `/memory delete`, schedule confirm-before-arm) still resolve through the ephemeral yes/no
/// commit/cancel switch. Tool approvals are durable now — a parked run lives in the
/// `approvals` table and resolves by authenticated button callback, never by a plain text reply.
public enum PendingConfirmation: Sendable, Equatable {
  case command(CommandConfirmation)
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
