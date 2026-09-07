import ClawCore

// MARK: - Media Intake

extension MessageRouter {
  func routeVoice(
    _ attachment: VoiceAttachment,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let voice else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: Self.unsupportedMediaText(kind: VoiceAttachment.mediaKindDescription)
      )
    }

    switch await voice.transcribe(attachment) {
    case .success(let transcript):
      return try await turnDispatch.dispatch(
        rawUpdate: rawUpdate,
        message: message,
        text: transcript,
        mode: mode,
        source: .untrusted
      )
    case .failure(.storageFull):
      return await replies.storageFull(target: .reply(to: message, mode: mode))
    case .failure(let failure):
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: failure.ownerReplyText
      )
    }
  }

  /// Mirrors `routeVoice`: access first, then availability, then the download — all before any
  /// update claim, so a cancellation mid-download leaves the update redeliverable. The caption
  /// dispatches directly and is never command-parsed nor offered to a parked confirmation: a photo
  /// carries no forward metadata, so an owner's own image and a forwarded one are indistinguishable
  /// and neither may steer a control path.
  ///
  /// A caption survives every arm that reaches a turn, including the opted-out one — see
  /// `routeImageWithoutService`. Only a failed download discards it, because there the reply names a
  /// fault the owner can act on rather than silently answering half the message.
  func routeImage(
    _ attachment: PhotoAttachment,
    caption: String?,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let images else {
      return try await routeImageWithoutService(
        caption: caption,
        rawUpdate: rawUpdate,
        message: message,
        mode: mode
      )
    }

    // After both guards, so neither a stranger nor a disabled service is ever told the bot is
    // awake. Whether the pulse lands is not checked and cannot be: the action auto-expires
    // server-side, so one that never arrives is no reason to fail a photo the owner is waiting on.
    let target = DeliveryTarget.reply(to: message, mode: mode)
    await typing?.sendTyping(chatId: target.chatId, messageThreadId: target.messageThreadId)

    switch await images.materialize(attachment) {
    case .success(let image):
      return try await turnDispatch.dispatch(
        rawUpdate: rawUpdate,
        message: message,
        text: ImageMarkers.photoContent(caption: caption),
        mode: mode,
        source: .untrusted,
        image: image
      )
    case .failure(let failure):
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: failure.ownerReplyText
      )
    }
  }
}

// MARK: - Image Fallback

private extension MessageRouter {
  /// The opted-out path, which still owes the owner an answer. A bare photo is only the photo, so
  /// the canned reply is the whole of it. A caption is the owner's own question and must not be
  /// discarded — the product tells them to set this very flag when their model cannot see, so this
  /// is a configuration they are steered into, not an edge case.
  ///
  /// The caption dispatches on the same direct, untrusted path the enabled branch uses. It is
  /// deliberately NOT routed back through command parsing or a parked confirmation: a photo carries
  /// no proof of who composed it, so one captioned `/stop` or `yes` must never steer a control path.
  /// The marker leads the content with no bytes behind it, so assembly renders the "no longer
  /// available" notice and the model is told a photo it cannot see was attached.
  func routeImageWithoutService(
    caption: String?,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let caption, caption.isEmpty == false else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: Self.unsupportedMediaText(kind: PhotoAttachment.mediaKindDescription)
      )
    }

    return try await turnDispatch.dispatch(
      rawUpdate: rawUpdate,
      message: message,
      text: ImageMarkers.photoContent(caption: caption),
      mode: mode,
      source: .untrusted
    )
  }
}
