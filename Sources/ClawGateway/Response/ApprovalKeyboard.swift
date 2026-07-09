/// The inline-keyboard envelope for a durable approval (§4.6/§5.4). `callback_data` is the only
/// state Telegram echoes back on a tap, so it carries just the single-use nonce and the verdict —
/// never the approval `id` (opaque and unguessable). `markup` is a DETERMINISTIC JSON string (no
/// clock, no randomness) so the outbox row it lands in is reproducible; `parse` is STRICT — only
/// "apr:<nonce>:y" / "apr:<nonce>:n" survive, so a malformed or forged shape is dropped before the
/// §6.2 auth chain ever runs.
public enum ApprovalKeyboard {
  public static let approveVerdict = "y"
  public static let denyVerdict = "n"

  private static let prefix = "apr"

  public static func callbackData(nonce: String, verdict: String) -> String {
    "\(prefix):\(nonce):\(verdict)"
  }

  /// Deterministic by construction: a fixed (sorted) key order, no whitespace, no Date or random.
  /// The nonce is base64url (`[A-Za-z0-9-_]`) and the verdicts/labels are ASCII, so nothing here
  /// needs JSON escaping. The client decodes this String to an object for the request body (§4.1).
  public static func markup(nonce: String) -> String {
    let approve = callbackData(nonce: nonce, verdict: approveVerdict)
    let deny = callbackData(nonce: nonce, verdict: denyVerdict)
    return
      #"{"inline_keyboard":[["#
      + #"{"callback_data":"\#(approve)","text":"Approve"},"#
      + #"{"callback_data":"\#(deny)","text":"Deny"}"#
      + "]]}"
  }

  public static func parse(_ callbackData: String) -> (nonce: String, approve: Bool)? {
    let parts =
      callbackData
      .split(separator: ":", omittingEmptySubsequences: false)
      .map(String.init)

    guard parts.count == 3, parts[0] == prefix else {
      return nil
    }

    let nonce = parts[1]
    guard nonce.isEmpty == false else {
      return nil
    }

    switch parts[2] {
    case approveVerdict:
      return (nonce, true)
    case denyVerdict:
      return (nonce, false)
    default:
      return nil
    }
  }
}
