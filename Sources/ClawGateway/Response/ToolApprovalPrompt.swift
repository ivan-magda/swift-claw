import ClawCore
import Foundation

/// The deterministic, gateway-authored approval prompt (D7/§9.2). The target is the full
/// canonical form, never model-authored, never truncated (FR-T5). Delivery-only: joined into the
/// outbox payload, never stored as assistant history. Exhaustive over `ApprovalReason`: a new
/// approval kind cannot compile without owner-facing copy here.
public enum ToolApprovalPrompt {
  public static func text(for request: ToolApprovalRequest) -> String {
    switch request.reason {
    case .exfilTrifecta:
      """
      ⚠ I want to fetch
      \(request.action.target)
      This session has read external content and holds private data.
      Reply yes to allow this one fetch; anything else cancels.
      """
    }
  }
}
