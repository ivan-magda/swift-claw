import ClawCore

// MARK: - Inbound Observation and Access

extension MessageRouter {
  /// The two updates the daemon can only take note of: its own membership changing, and Telegram
  /// replacing a chat id under a running configuration. Both run ahead of `normalize`, which would
  /// drop them as contentless — and the generic drop line is exactly the wrong trace for an event
  /// whose whole value is that an operator sees it.
  func noteObservedEvent(in rawUpdate: RawUpdate) -> HandleOutcome? {
    if let membership = rawUpdate.myChatMember {
      logMembership(membership, updateId: rawUpdate.updateId)
      return .skipped
    }
    let inbound = rawUpdate.message ?? rawUpdate.editedMessage
    if let inbound, let newChatId = inbound.migratedToChatId {
      logMigration(from: inbound, to: newChatId)
      return .skipped
    }
    return nil
  }

  /// The overheard branch. Only typed words are kept: a sticker, a voice note and a photo all
  /// need bytes the bot deliberately never fetched for a message that did not name it, so there is
  /// nothing of them to write down. The room's transcript therefore holds what was said in it, and
  /// no placeholder for what was shown.
  func observe(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async -> HandleOutcome {
    guard case .text(let text) = message.content else {
      logger.debug(
        "update \(rawUpdate.updateId) in chat \(message.chatId) does not address the bot, skipping"
      )
      return .skipped
    }
    return await turnDispatch.observe(
      rawUpdate: rawUpdate,
      message: message,
      text: text,
      mode: mode
    )
  }

  /// Default-deny, applied ONCE for every update, before the content switch — so a refused photo
  /// or voice note is never downloaded. A stranger's /start gets THEIR own id to request access
  /// (never the allowlist, never a turn); every other DM refusal is the private-bot line, which is
  /// also all a stranger may learn about unsupported media.
  ///
  /// An unlisted chat is answered with silence but still logged: the id and title are the only way
  /// an operator can learn what to put in `CLAW_GROUP_CHATS`, since the bot says nothing in a room
  /// until that id is already configured.
  func denyAccess(
    _ denial: AccessDenial,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    switch denial {
    case .unlistedChat:
      let title = message.chatTitle ?? "(untitled)"
      logger.info(
        """
        ignoring update \(rawUpdate.updateId) from unlisted chat \(message.chatId) "\(title)" (\(message.chatKind.apiValue))
        """
      )
      return .skipped
    case .privateStranger:
      guard isStart(message.content) else {
        return await replies.sendPrivateBot(
          updateId: rawUpdate.updateId,
          target: .chat(message.chatId)
        )
      }
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .chat(message.chatId),
        text: Self.unauthorizedStartText(userId: message.userId)
      )
    }
  }

  /// The `/start` refusal doubles as onboarding: its last line is pasteable into clawd.env.
  static func unauthorizedStartText(userId: Int64) -> String {
    """
    This is a private bot. Your Telegram user ID is \(userId). To authorize it, the owner \
    adds this line to clawd.env and restarts clawd:
    CLAW_ALLOWLIST=\(userId)
    """
  }
}

// MARK: - Event Logging and Command Identification

private extension MessageRouter {
  /// Membership is observed, never acted on: an allowlist lives in configuration, so a room the
  /// bot was just added to still says nothing until an operator puts its id there. The log is how
  /// they learn the id, and how a silent removal or a rights change stops looking like a bug.
  func logMembership(_ membership: RawChatMemberUpdate, updateId: Int64) {
    let title = membership.chatTitle ?? "(untitled)"
    let actor = membership.actorDisplayName ?? membership.actorUserId.map(String.init) ?? "someone"
    let transition = "\(membership.oldStatus.apiValue) → \(membership.newStatus.apiValue)"
    let room = "chat \(membership.chatId) \"\(title)\" (\(membership.chatKind.apiValue))"
    switch membership.change {
    case .added:
      logger.notice("\(actor) added the bot to \(room): \(transition)")
    case .removed:
      logger.notice("\(actor) removed the bot from \(room): \(transition)")
    case .updated:
      logger.notice("\(actor) changed the bot's rights in \(room): \(transition)")
    case .unchanged:
      logger.debug("membership update \(updateId) changed nothing in \(room): \(transition)")
    }
  }

  /// Telegram replaces a group's chat id when it upgrades to a supergroup, and the old id stops
  /// existing. Rewriting `CLAW_GROUP_CHATS` at runtime would silently re-point an access grant at
  /// an id nobody approved, so the daemon does the opposite: it goes quiet in that room and says
  /// exactly what to edit.
  func logMigration(from message: RawMessage, to newChatId: Int64) {
    let title = message.chatTitle ?? "(untitled)"
    logger.error(
      """
      chat \(message.chatId) "\(title)" was upgraded to a supergroup and is now chat \(newChatId); \
      clawd will ignore it until CLAW_GROUP_CHATS lists \(newChatId) — update clawd.env and restart
      """
    )
  }

  /// True only for `/start` — the one refusal that answers with the sender's own id.
  func isStart(_ content: IncomingMessage.Content) -> Bool {
    guard case .text(let text) = content else {
      return false
    }
    if case .start = Command.parse(text, botUsername: botUsername) {
      return true
    }
    return false
  }
}
