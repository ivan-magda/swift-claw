import ClawCore
import Foundation

public enum PendingConfirmation: Sendable, Equatable {
  case rememberWrite(MemoryWriteRequest)
  case deleteItem(id: Int64)
  case exfilFetch(ExfilApprovalRequest)
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
