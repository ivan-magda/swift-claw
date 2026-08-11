import ClawCore

// MARK: - Image Attachment

extension TurnRunner {
  /// The images this session's inbound photos left behind, whatever survived eviction.
  func cachedImages(sessionId: Int64) async -> [Int64: ImagePart] {
    await imageCache.images(sessionId: sessionId)
  }

  /// Moves cached images onto the history rows they arrived on, matching by message id while
  /// `history` and `historyMessageIds` are still parallel — the last point at which they are, since
  /// assembly sanitizes the history and drops rows before it renders. Carrying the image on the row
  /// is what lets sanitizing, grouping, and fitting all move it without knowing it exists.
  ///
  /// Budget selection runs after the match, not before, so the aggregate cap is only ever spent on
  /// images that actually landed inside the history window.
  static func attach(
    _ images: [Int64: ImagePart],
    to snapshot: SessionContextSnapshot
  ) -> SessionContextSnapshot {
    guard images.isEmpty == false else {
      return snapshot
    }

    let paired = min(snapshot.history.count, snapshot.historyMessageIds.count)
    var inWindow: [Int64: ImagePart] = [:]
    for messageId in snapshot.historyMessageIds.prefix(paired) {
      guard let image = images[messageId] else {
        continue
      }
      inWindow[messageId] = image
    }

    let kept = ImageReplaySelection.affordable(
      inWindow,
      aggregateCap: ImageBounds.maximumAggregateReplayBytes
    )
    guard kept.isEmpty == false else {
      return snapshot
    }

    let history = snapshot.history.enumerated().map { offset, message in
      guard
        offset < snapshot.historyMessageIds.count,
        let image = kept[snapshot.historyMessageIds[offset]]
      else {
        return message
      }
      return StoredMessage(
        role: message.role,
        content: message.content,
        provenance: message.provenance,
        toolCallsJSON: message.toolCallsJSON,
        toolCallId: message.toolCallId,
        providerState: message.providerState,
        image: image
      )
    }

    return SessionContextSnapshot(
      history: history,
      historyMessageIds: snapshot.historyMessageIds,
      windowStartMessageId: snapshot.windowStartMessageId,
      isTainted: snapshot.isTainted,
      hasPrivateData: snapshot.hasPrivateData
    )
  }
}
