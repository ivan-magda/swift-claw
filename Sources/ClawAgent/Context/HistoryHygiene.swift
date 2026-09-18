import ClawCore
import Foundation

/// A complete tool exchange or one plain conversational row, kept or dropped atomically by fitting.
struct HistoryGroup {
  let id: String
  let messages: [StoredMessage]
}

/// The renderer's belt-and-braces guard: drops tool rows with no owning anchor and
/// any anchor whose observations are incomplete, so a malformed history (crash, partial commit)
/// can never become a wire-protocol 400. The LOAD seam already bounds windows by conversational
/// rows; no-orphan holds only because BOTH seams enforce it.
enum HistoryHygiene {
  static func sanitize(_ history: [StoredMessage]) -> [StoredMessage] {
    groups(from: history).flatMap(\.messages)
  }

  static func groups(from history: [StoredMessage]) -> [HistoryGroup] {
    var groups: [HistoryGroup] = []
    var sanitizedRowCount = 0
    var index = 0

    while index < history.count {
      let message = history[index]

      if message.role == .tool {
        index += 1  // an orphaned tool row: no preceding anchor claimed it
        continue
      }

      let anchorCalls = message.toolCallsJSON.map(ToolCallCoding.decode) ?? []
      guard message.role == .assistant, anchorCalls.isEmpty == false else {
        groups.append(HistoryGroup(id: "history-\(sanitizedRowCount)", messages: [message]))
        sanitizedRowCount += 1
        index += 1
        continue
      }

      // Collect the contiguous tool rows following this anchor.
      var observationRows: [StoredMessage] = []
      var cursor = index + 1
      while cursor < history.count, history[cursor].role == .tool {
        observationRows.append(history[cursor])
        cursor += 1
      }

      let expectedIDs = Set(anchorCalls.map(\.id))
      let presentIDs = Set(observationRows.compactMap(\.toolCallID))
      if expectedIDs.isSubset(of: presentIDs) {
        let messages = [message] + observationRows
        groups.append(HistoryGroup(id: "history-\(sanitizedRowCount)", messages: messages))
        sanitizedRowCount += messages.count
      }
      // else: drop the anchor AND its partial rows — the exchange is incomplete.
      index = cursor
    }

    return groups
  }
}
