/// The inline-keyboard envelope for a durable approval. `callback_data` is the only
/// state Telegram echoes back on a tap, so it carries just the single-use nonce and the verdict —
/// never the approval `id` (opaque and unguessable). `markup` is a DETERMINISTIC JSON string (no
/// clock, no randomness) so the outbox row it lands in is reproducible; `parse` is STRICT — only
/// "apr:<nonce>:y" / "apr:<nonce>:t" / "apr:<nonce>:n" survive, so a malformed or forged shape is
/// dropped before the auth chain ever runs.
public enum ApprovalKeyboard {
  /// What the owner tapped. `approveForTurn` widens the grant to the rest of the turn and is
  /// offered only by an approval whose reason allows it; the callback path re-checks that, so a
  /// verdict for a button the prompt never drew resolves as a plain single approval.
  public enum Verdict: String, Sendable, Equatable {
    case approve = "y"
    case approveForTurn = "t"
    case deny = "n"
  }

  private static let prefix = "apr"

  public static func callbackData(nonce: String, verdict: Verdict) -> String {
    "\(prefix):\(nonce):\(verdict.rawValue)"
  }

  /// Deterministic by construction: a fixed (sorted) key order, no whitespace, no Date or random.
  /// The nonce is base64url (`[A-Za-z0-9-_]`) and the verdicts/labels are ASCII, so nothing here
  /// needs JSON escaping. The client decodes this String to an object for the request body.
  public static func markup(nonce: String, offersTurnWindow: Bool = false) -> String {
    let approve = callbackData(nonce: nonce, verdict: .approve)
    let deny = callbackData(nonce: nonce, verdict: .deny)

    var buttons = [#"{"callback_data":"\#(approve)","text":"Approve"}"#]
    if offersTurnWindow {
      let forTurn = callbackData(nonce: nonce, verdict: .approveForTurn)
      buttons.append(#"{"callback_data":"\#(forTurn)","text":"Approve for this turn"}"#)
    }
    buttons.append(#"{"callback_data":"\#(deny)","text":"Deny"}"#)

    return #"{"inline_keyboard":[["# + buttons.joined(separator: ",") + "]]}"
  }

  public static func parse(_ callbackData: String) -> (nonce: String, verdict: Verdict)? {
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

    guard let verdict = Verdict(rawValue: parts[2]) else {
      return nil
    }
    return (nonce, verdict)
  }
}
