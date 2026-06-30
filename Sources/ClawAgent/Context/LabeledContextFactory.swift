import ClawCore
import Foundation

public enum LabeledContextFactory {
  public static func make(label: String, content: String) -> LabeledContext {
    LabeledContext(label: label, content: content, nonce: makeNonce())
  }

  // Context-fence freshness boundary from spec §7.6; not an approval callback nonce (§6.5).
  private static func makeNonce() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}
