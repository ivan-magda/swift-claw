import ClawCore
import Foundation

/// The renderer's belt-and-braces guard (rev.1 H2): drops tool rows with no owning anchor and
/// any anchor whose observations are incomplete, so a malformed history (crash, partial commit)
/// can never become a wire-protocol 400. The LOAD seam already bounds windows by conversational
/// rows; no-orphan holds only because BOTH seams enforce it.
public enum HistoryHygiene {
  public static func sanitize(_ history: [StoredMessage]) -> [StoredMessage] {
    var sanitized: [StoredMessage] = []
    var index = 0

    while index < history.count {
      let message = history[index]

      if message.role == .tool {
        index += 1  // an orphaned tool row: no preceding anchor claimed it
        continue
      }

      let anchorCalls = message.toolCallsJSON.map(ToolCallCoding.decode) ?? []
      guard message.role == .assistant, anchorCalls.isEmpty == false else {
        sanitized.append(message)
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

      let expectedIds = Set(anchorCalls.map(\.id))
      let presentIds = Set(observationRows.compactMap(\.toolCallId))
      if expectedIds.isSubset(of: presentIds) {
        sanitized.append(message)
        sanitized.append(contentsOf: observationRows)
      }
      // else: drop the anchor AND its partial rows — the exchange is incomplete.
      index = cursor
    }

    return sanitized
  }
}
