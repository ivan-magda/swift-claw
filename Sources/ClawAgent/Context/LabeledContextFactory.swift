import ClawCore
import Foundation

public enum LabeledContextFactory {
  public static func make(label: String, content: String) -> LabeledContext {
    LabeledContext(label: label, content: content, nonce: makeNonce())
  }

  // Context-fence freshness boundary; not an approval callback nonce.
  private static func makeNonce() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}
