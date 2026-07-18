import Foundation

/// The transport-level rules of `text/event-stream`, shared by every route that speaks it.
///
/// Framing is the part of SSE that is the same wherever it is spoken: where one event ends, and
/// which of its lines carry payload. What those payloads *mean* is a route's own business, which is
/// why only those two questions live here — the Chat Completions chunk schema and the Responses
/// event schema agree on nothing past this line.
enum SSEFraming {
  private static let lineFeed: UInt8 = 0x0A
  private static let carriageReturn: UInt8 = 0x0D

  /// The end of one event: a blank line in either its LF or CRLF form, whichever appears first.
  ///
  /// One forward pass rather than a search per form. Searching for both and taking the earlier one
  /// reads more directly, but a stream only ever uses one of them, so the other's search runs to the
  /// end of the buffer every single call — which is quadratic over a delivery of many small events,
  /// and is the difference between framing 4 MiB in milliseconds and in minutes.
  static func delimiterRange(in data: Data) -> Range<Data.Index>? {
    var index = data.startIndex
    let end = data.endIndex

    while index < end {
      switch data[index] {
      case lineFeed:
        let next = data.index(after: index)
        if next < end, data[next] == lineFeed {
          return index..<data.index(after: next)
        }
      case carriageReturn:
        if let upper = crlfBlankLineEnd(in: data, from: index) {
          return index..<upper
        }
      default:
        break
      }
      index = data.index(after: index)
    }
    return nil
  }

  /// The end of a `\r\n\r\n` beginning at `index`, or nil when that is not what is there.
  private static func crlfBlankLineEnd(in data: Data, from index: Data.Index) -> Data.Index? {
    guard let end = data.index(index, offsetBy: 4, limitedBy: data.endIndex) else {
      return nil
    }
    let blankLine = [carriageReturn, lineFeed, carriageReturn, lineFeed]
    return data[index..<end].elementsEqual(blankLine) ? end : nil
  }

  /// The `data:` field values of one SSE event: comments (`:`) and non-`data` fields are dropped,
  /// and a single leading space after the colon is stripped, per the SSE field-parsing rules.
  static func dataPayloadLines(in text: String) -> [String] {
    // The CRLF fold is a bridged Foundation pass over the whole event; a stream delivers one event
    // at a time but many thousands of them, so an LF-only event — the overwhelmingly common form —
    // skips the fold on a cheap byte scan instead of paying it every single event.
    let normalized =
      text.utf8.contains(carriageReturn)
      ? text.replacingOccurrences(of: "\r\n", with: "\n")
      : text
    return normalized.split(separator: "\n", omittingEmptySubsequences: false)
      .compactMap { rawLine -> String? in
        var line = rawLine

        if line.last == "\r" {
          line.removeLast()
        }

        if line.hasPrefix(":") {
          return nil
        }

        guard line.hasPrefix("data:") else {
          return nil
        }
        var value = line.dropFirst(5)

        if value.first == " " {
          value = value.dropFirst()
        }

        return String(value)
      }
  }
}
