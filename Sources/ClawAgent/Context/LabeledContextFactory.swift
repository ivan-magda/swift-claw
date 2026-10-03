import ClawCore
import Foundation

public enum LabeledContextFactory {
  public static func make(label: String, content: String) -> LabeledContext {
    LabeledContext(label: label, content: content, nonce: makeNonce())
  }
}

// MARK: - Fence Nonces

private extension LabeledContextFactory {
  // Context-fence freshness boundary; not an approval callback nonce.
  static func makeNonce() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}
