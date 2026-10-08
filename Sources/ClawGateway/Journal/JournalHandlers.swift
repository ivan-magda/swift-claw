import ClawCore
import Foundation

/// Inspection remains composed independently of automatic capture and inference.
package struct JournalCommandSurface: Sendable {
  let policy: JournalPolicy
  let store: any JournalStore
  let files: any JournalFiles
  let mutationGate: WorkspaceMutationGate

  package init(
    policy: JournalPolicy,
    store: any JournalStore,
    files: any JournalFiles,
    mutationGate: WorkspaceMutationGate
  ) {
    self.policy = policy
    self.store = store
    self.files = files
    self.mutationGate = mutationGate
  }
}

struct JournalDeleteResult: Sendable, Equatable {
  enum Outcome: Sendable, Equatable {
    case deleted
    case missing
    case failed
  }

  let outcome: Outcome
  let cancelledPendingCount: Int
}

struct JournalHandlers: Sendable {
  let surface: JournalCommandSurface
  let sessionMessages: any SessionMessageStore
  let pendingConfirmations: PendingConfirmationRegistry
  let replies: ReplySender
  let now: @Sendable () -> Date

  func isOwner(_ message: IncomingMessage) -> Bool {
    guard let owner = surface.policy.ownerUserID, owner > 0 else {
      return false
    }
    return message.chatKind == .private && message.userID == owner && message.chatID == owner
  }

  func handle(command: JournalCommand, message: IncomingMessage) async -> HandleOutcome {
    guard isOwner(message) else {
      return await replies.sendPrivateBot(updateID: message.updateID, target: .chat(message.chatID))
    }

    do {
      return try await handleOwner(command, message: message)
    } catch {
      return error.outcome
    }
  }

  func deleteConfirmed(
    day: JournalDay,
    ownerUserID: Int64,
    now: Date
  ) async -> JournalDeleteResult {
    guard ownerUserID > 0, ownerUserID == surface.policy.ownerUserID else {
      return JournalDeleteResult(outcome: .failed, cancelledPendingCount: 0)
    }

    let store = surface.store
    let files = surface.files
    return await surface.mutationGate.perform {
      let cancelledPendingCount: Int
      do {
        cancelledPendingCount = try store.cancelDay(day, ownerUserID: ownerUserID, now: now)
      } catch {
        return JournalDeleteResult(outcome: .failed, cancelledPendingCount: 0)
      }

      // Cancellation commits first. File failure must not restore queued publication.
      let snapshot = files.load(day: day)
      do {
        try files.delete(day: day)
        return JournalDeleteResult(
          outcome: snapshot.outcome == .missing ? .missing : .deleted,
          cancelledPendingCount: cancelledPendingCount
        )
      } catch {
        return JournalDeleteResult(
          outcome: .failed,
          cancelledPendingCount: cancelledPendingCount
        )
      }
    }
  }
}

// MARK: - Authenticated Commands

private extension JournalHandlers {
  func handleOwner(
    _ command: JournalCommand,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let replyText: String
    switch command {
    case .invalid:
      replyText = CommandReplies.journalUsage
    case .show(let day):
      replyText = show(day: day)
    case .status:
      replyText = try await status(message: message)
    case .delete(let day):
      return try await requestDelete(day: day, message: message)
    }

    return await replies.sendCanned(
      updateID: message.updateID,
      target: .chat(message.chatID),
      text: replyText
    )
  }

  func status(message: IncomingMessage) async throws(RoutingHalt) -> String {
    let status = try await replies.perform(
      "journal status",
      updateID: message.updateID,
      target: .chat(message.chatID)
    ) {
      try surface.store.status(ownerUserID: message.userID, now: now())
    }

    let recentDates: String
    do {
      recentDates = try surface.files.recentDays(limit: 10)
        .map(\.isoDate)
        .joined(separator: ", ")
    } catch {
      return JournalHealth.render(policy: surface.policy, status: status)
        + "\nRecent dates: unavailable"
    }

    return JournalHealth.render(policy: surface.policy, status: status)
      + "\nRecent dates: \(recentDates.isEmpty ? "none" : recentDates)"
  }

  func show(day: JournalDay) -> String {
    let snapshot = surface.files.load(day: day)
    switch snapshot.outcome {
    case .missing:
      return "No journal for \(day.isoDate)."
    case .unreadable:
      return "Journal \(day.isoDate) is unreadable."
    case .overCap:
      return "Journal \(day.isoDate) exceeds the file size limit."
    case .present:
      let heading = "Journal \(day.isoDate)\n"
      let notice = "\n[Shortened; read the workspace file for the full text.]"
      let limit = TelegramMessageLimits.maxPlainMessageCharacters

      let headingScalars = heading.unicodeScalars.count
      if headingScalars + snapshot.text.unicodeScalars.count <= limit {
        return heading + snapshot.text
      }

      var remainingScalars = limit - headingScalars - notice.unicodeScalars.count
      let excerpt = snapshot.text.prefix { character in
        let scalarCount = character.unicodeScalars.count
        guard scalarCount <= remainingScalars else {
          return false
        }

        remainingScalars -= scalarCount

        return true
      }

      return heading + excerpt + notice
    }
  }

  func requestDelete(
    day: JournalDay,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let pendingSourceCount = try await replies.perform(
      "journal pending count",
      updateID: message.updateID,
      target: .chat(message.chatID)
    ) {
      try surface.store.pendingCount(day: day, ownerUserID: message.userID)
    }

    let claimOutcome = try await replies.perform(
      "journal delete claim",
      updateID: message.updateID,
      target: .chat(message.chatID)
    ) {
      try sessionMessages.claimCommandUpdate(
        updateID: message.updateID,
        sessionKey: SessionKey.telegramDM(chatID: message.chatID),
        now: now()
      )
    }
    guard case .claimed(let sessionID) = claimOutcome else {
      return replies.skipDuplicate(updateID: message.updateID)
    }

    await pendingConfirmations.park(.journalDelete(day: day), sessionID: sessionID)

    return await replies.sendCommandAck(
      updateID: message.updateID,
      target: .chat(message.chatID),
      text: """
        Delete journal \(day.isoDate), including your edits, and \
        cancel \(pendingSourceCount) pending sources?
        In-flight summaries retain usage but cannot publish. Other days, conversations and \
        running Coder jobs remain. Later activity may recreate this date.
        Reply yes to confirm, or no to cancel.
        """
    )
  }
}
