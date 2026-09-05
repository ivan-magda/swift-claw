import ClawCore
import Foundation

/// One exchange-grouping unit: an assistant anchor (`tool_calls`) plus its tool rows, or a single
/// plain conversational message. The atomic droppable unit — never a partial exchange on the wire.
private struct HistoryGroup {
  let id: String
  let messages: [StoredMessage]
}

// MARK: - History Section and Message Rendering

extension ContextBuilder {
  func historySection(snapshot: SessionContextSnapshot, residual: Int) -> FittableSection? {
    // No `cap > 0` early-return: even when fixed sections leave a zero residual, the newest
    // history unit (the current turn) must reach the fitter, which keeps it as a non-droppable
    // floor so the model always sees the message it is answering.
    let cap = cap(for: .history, residual: residual)
    let groups = historyGroups(from: snapshot.history)

    let units = groups.reversed().map { group in
      SectionUnit(
        id: group.id,
        content: group.messages.map { message in
          message.content + (message.toolCallsJSON ?? "")
        }.joined(separator: "\n"),
        canTruncate: false
      )
    }

    guard units.isEmpty == false else {
      return nil
    }

    return section(id: .history, cap: cap, units: units)
  }

  func renderMessages(
    fitted: [FittedSection],
    snapshot: SessionContextSnapshot
  ) -> [ChatMessage] {
    let historyMessages = fittedHistoryMessages(fitted: fitted, snapshot: snapshot)
    // Compare GROUPS, not raw rows: one unit per group by construction, so a kept-unit-count
    // shortfall against the full group count means an exchange (or plain row) was dropped.
    let keptHistoryGroupCount = Set(
      fitted.first { section in
        section.id == .history
      }?.units.map(\.id) ?? []
    ).count
    let historyWasTruncated = keptHistoryGroupCount < historyGroups(from: snapshot.history).count

    let systemContent =
      fitted
      .filter { section in
        section.tier == .system
      }
      .map(\.content)
      .joined(separator: "\n\n")
      + (historyWasTruncated ? Self.historyTruncatedMarker : "")
    var messages = [ChatMessage(role: .system, content: systemContent)]

    let untrusted =
      fitted
      .filter { section in
        section.tier == .untrustedLabeled
      }
      .map { section in
        LabeledContextFactory.make(
          label: label(for: section.id),
          content: section.content
        ).render()
      }
      .joined(separator: "\n\n")
    if untrusted.isEmpty == false {
      messages.append(ChatMessage(role: .user, content: untrusted))
    }

    messages.append(contentsOf: historyMessages)
    return messages
  }
}

// MARK: - History Groups

private extension ContextBuilder {
  static let historyTruncatedMarker = "\n\n[…earlier conversation truncated]"

  /// Groups sanitized history so each exchange is ONE atomic droppable unit. Group ids are stable
  /// per assembly ("history-<index of the group's first row>").
  func historyGroups(from history: [StoredMessage]) -> [HistoryGroup] {
    let sanitized = HistoryHygiene.sanitize(history)
    var groups: [HistoryGroup] = []
    var index = 0

    while index < sanitized.count {
      let message = sanitized[index]
      let anchorCalls = message.toolCallsJSON.map(ToolCallCoding.decode) ?? []

      guard message.role == .assistant, anchorCalls.isEmpty == false else {
        groups.append(HistoryGroup(id: "history-\(index)", messages: [message]))
        index += 1
        continue
      }

      var grouped = [message]
      var cursor = index + 1

      while cursor < sanitized.count, sanitized[cursor].role == .tool {
        grouped.append(sanitized[cursor])
        cursor += 1
      }

      groups.append(HistoryGroup(id: "history-\(index)", messages: grouped))
      index = cursor
    }

    return groups
  }

  /// The one render seam for both native assistant anchors (with decoded `toolCalls`) and fenced
  /// tool rows (labeled by the owning anchor's declared fence label). Kept groups come from the
  /// fitter verbatim — one `SectionUnit` per group — so this only re-expands each surviving
  /// group's rows.
  func fittedHistoryMessages(
    fitted: [FittedSection],
    snapshot: SessionContextSnapshot
  ) -> [ChatMessage] {
    guard let historySection = fitted.first(where: { section in section.id == .history }) else {
      return []
    }

    let keptIDs = Set(historySection.units.map(\.id))
    let groups = historyGroups(from: snapshot.history)
    var rendered: [ChatMessage] = []

    for group in groups where keptIDs.contains(group.id) {
      // The anchor's id→name map labels each tool row's fence. A provider-authored response could
      // duplicate a tool_call id, and the name a row resolves to now decides how much the prompt
      // trusts its content — so a duplicated id names nobody and its rows fall back to the
      // unattributed label, rather than the first declaration lending them its fence.
      let anchorCalls = group.messages.first?.toolCallsJSON.map(ToolCallCoding.decode) ?? []
      let callsPerId = anchorCalls.reduce(into: [String: Int]()) { counts, call in
        counts[call.id, default: 0] += 1
      }
      let namesByCallId = Dictionary(
        uniqueKeysWithValues:
          anchorCalls
          .filter { call in
            callsPerId[call.id] == 1
          }
          .map { call in
            (call.id, call.name)
          }
      )

      for message in group.messages {
        switch message.role {
        case .tool:
          let label =
            message.toolCallId
            .flatMap { callId in
              namesByCallId[callId]
            }
            .map(fenceLabels.label(forToolNamed:))
            ?? ToolFenceLabels.unattributed
          rendered.append(
            ChatMessage(
              role: .tool,
              content: LabeledContextFactory.make(
                label: label,
                content: message.content
              ).render(),
              toolCallId: message.toolCallId
            )
          )
        case .assistant:
          rendered.append(
            ChatMessage(
              role: .assistant,
              content: message.content,
              toolCalls: message.toolCallsJSON.map(ToolCallCoding.decode) ?? [],
              providerState: message.providerState
            )
          )
        case .user:
          rendered.append(userMessage(from: message))
        case .system:
          rendered.append(ChatMessage(role: .system, content: message.content))
        }
      }
    }

    return rendered
  }
}

// MARK: - User Messages and Context Labels

private extension ContextBuilder {
  /// Provenance decides the fence and nothing else. The image rides on every user row, trusted or
  /// not: gating it on provenance would let a single change of tier drop an image with no error and
  /// no failing test.
  func userMessage(from message: StoredMessage) -> ChatMessage {
    var body = message.content
    if message.provenance == .untrusted {
      body = LabeledContextFactory.make(
        label: Self.untrustedUserLabel,
        content: message.content
      ).render()
    }

    // Outside the fence, deliberately: this is our own assertion about system state, and fencing it
    // would label our words as sender-supplied input.
    if photoBytesAreMissing(message) {
      body += "\n\(ImageMarkers.unavailable)"
    }

    let parts: [MessageContent.Part] =
      message.image.map { image in
        [.image(image), .text(body)]
      } ?? [.text(body)]
    return ChatMessage(role: .user, content: MessageContent(parts: parts))
  }

  /// True when a row records a photo whose bytes did not survive to assembly — evicted under cache
  /// pressure, dropped by the replay budget, or lost to a restart. Image bytes are never persisted,
  /// so the stored marker is the only evidence left. Provenance is deliberately not consulted, for
  /// the same reason the image itself rides on every tier.
  func photoBytesAreMissing(_ message: StoredMessage) -> Bool {
    guard message.image == nil else {
      return false
    }
    return ImageMarkers.marksPhoto(message.content)
  }

  func label(for id: ContextRowID) -> String {
    switch id {
    case .userFile:
      "USER.md"
    case .memoryFile:
      "MEMORY.md"
    case .memoryItems:
      "memory_items"
    case .recall:
      "recall"
    case .skills:
      WorkspaceSkills.fenceLabel
    case .lessons:
      Self.lessonsLabel
    case .policy, .systemWorkspace, .tools, .metadata, .history:
      id.rawValue
    }
  }
}
