import ClawCore

// MARK: - Image Attachment

extension TurnRunner {
  /// The images this session's inbound photos left behind, whatever survived eviction.
  func cachedImages(sessionID: Int64) async -> [Int64: ImagePart] {
    await imageCache.images(sessionID: sessionID)
  }

  /// Moves cached images onto the history rows they arrived on, matching by message id while
  /// `history` and `historyMessageIds` are still parallel — the last point at which they are, since
  /// assembly sanitizes the history and drops rows before it renders. Carrying the image on the row
  /// is what lets sanitizing, grouping, and fitting all move it without knowing it exists.
  ///
  /// Budget selection runs after the match, not before, so the aggregate cap is only ever spent on
  /// images that actually landed inside the history window.
  static func attach(_ images: [Int64: ImagePart], to snapshot: SessionContextSnapshot)
    -> SessionContextSnapshot
  {
    guard images.isEmpty == false else {
      return snapshot
    }

    let paired = min(snapshot.history.count, snapshot.historyMessageIDs.count)
    var inWindow: [Int64: ImagePart] = [:]
    for messageID in snapshot.historyMessageIDs.prefix(paired) {
      guard let image = images[messageID] else {
        continue
      }
      inWindow[messageID] = image
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
        offset < snapshot.historyMessageIDs.count,
        let image = kept[snapshot.historyMessageIDs[offset]]
      else {
        return message
      }
      return StoredMessage(
        role: message.role,
        content: message.content,
        provenance: message.provenance,
        toolCallsJSON: message.toolCallsJSON,
        toolCallID: message.toolCallID,
        providerState: message.providerState,
        image: image
      )
    }

    return SessionContextSnapshot(
      sessionKey: snapshot.sessionKey,
      history: history,
      historyMessageIDs: snapshot.historyMessageIDs,
      windowStartMessageID: snapshot.windowStartMessageID,
      isTainted: snapshot.isTainted,
      hasPrivateData: snapshot.hasPrivateData
    )
  }
}
