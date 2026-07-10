import Crypto
import Foundation

/// The ONE decoder for `memory_write` tool arguments (§8.2), shared by the gate-time tool
/// (ClawTools) and the approval waiter's rebuild (ClawGateway) — both sides run this exact
/// derivation, so the stored item can never drift from what the owner approved. Lives in
/// ClawCore because ClawGateway never imports ClawTools (module DAG).
public enum MemoryWriteArguments {
  public enum Outcome: Sendable {
    case parsed(MemoryWriteRequest)
    case invalid(reason: String)
  }

  public static func parse(_ arguments: JSONValue, sessionId: Int64?) -> Outcome {
    guard
      let text = arguments.objectValue?["text"]?.stringValue,
      text.isEmpty == false
    else {
      return .invalid(reason: "memory_write needs a non-empty \"text\" argument.")
    }
    guard
      let rawKind = arguments.objectValue?["kind"]?.stringValue,
      let kind = MemoryKind(rawValue: rawKind)
    else {
      return .invalid(
        reason: "memory_write needs a \"kind\" of user, feedback, project, or reference."
      )
    }

    let importance: Importance
    switch arguments.objectValue?["importance"]?.stringValue {
    case nil:
      importance = .normal
    case "low":
      importance = .low
    case "normal":
      importance = .normal
    case "high":
      importance = .high
    default:
      return .invalid(reason: "importance must be low, normal, or high.")
    }

    let sensitivity: Sensitivity
    switch arguments.objectValue?["sensitivity"]?.stringValue {
    case nil:
      sensitivity = .normal
    case .some(let raw):
      guard let parsed = Sensitivity(rawValue: raw) else {
        return .invalid(reason: "sensitivity must be normal or high.")
      }
      sensitivity = parsed
    }

    do {
      let request = try MemoryWriteBuilder.build(
        rawText: text,
        kind: kind,
        sessionId: sessionId,
        source: .assistant,
        importance: importance,
        sensitivity: sensitivity
      )
      return .parsed(request)
    } catch MemoryWriteBuildError.emptyAfterNormalization {
      return .invalid(reason: "Nothing savable remains after normalization.")
    } catch {
      // A future builder error must refuse with a truthful generic reason, never borrow the
      // empty-after-normalization copy above.
      return .invalid(reason: "memory_write could not build a savable item from those arguments.")
    }
  }

  /// The §8.2 canonical target: `memory_item:<kind>:<hash16>`, hash16 = first 16 hex chars of
  /// SHA-256 over the NORMALIZED stored text — the identity the approval binds to.
  public static func canonicalTarget(for request: MemoryWriteRequest) -> String {
    let digest = SHA256.hash(data: Data(request.item.text.utf8))
    let hash16 = digest.prefix(8).map { byte in String(format: "%02x", byte) }.joined()
    return "memory_item:\(request.item.kind.rawValue):\(hash16)"
  }

  /// Owner-facing label for the Int-raw `Importance` (the wire vocabulary is the string form).
  public static func importanceLabel(_ importance: Importance) -> String {
    switch importance {
    case .low: "low"
    case .normal: "normal"
    case .high: "high"
    }
  }
}
