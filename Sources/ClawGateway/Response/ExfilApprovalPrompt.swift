import Foundation

/// The deterministic, gateway-authored approval prompt (D7/§9.2). The URL is the full canonical
/// form, never model-authored, never truncated (FR-T5). Delivery-only: joined into the outbox
/// payload, never stored as assistant history.
public enum ExfilApprovalPrompt {
  public static func text(canonicalURL: String) -> String {
    """
    ⚠ I want to fetch
    \(canonicalURL)
    This session has read external content and holds private data.
    Reply yes to allow this one fetch; anything else cancels.
    """
  }
}
