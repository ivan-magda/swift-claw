import ClawCore
import Foundation

/// The deterministic, gateway-authored approval prompt (D7/§5.4). Every owner-visible field is
/// authored HERE, never by the model, and the fully-resolved canonical target is never truncated
/// (FR-T5). Delivery-only: joined into the outbox payload, never stored as assistant history.
/// Exhaustive over `ApprovalReason` — a new approval kind cannot compile without owner-facing copy.
public enum ToolApprovalPrompt {
  /// Everything the §5.4 durable-approval prompt renders. The banners are decided by the suspend
  /// commit (Task 14) from the originating turn's taint state and the target's identity; the
  /// renderer stays a pure function of its input.
  public struct Input: Sendable, Equatable {
    public let recorded: RecordedToolAction
    /// The originating turn ingested untrusted content (§5.4 TAINT banner).
    public let taintBanner: Bool
    /// The canonical target is SOUL/AGENTS/USER/MEMORY .md (§5.4 privileged-file banner).
    public let privilegedFileBanner: Bool

    public init(recorded: RecordedToolAction, taintBanner: Bool, privilegedFileBanner: Bool) {
      self.recorded = recorded
      self.taintBanner = taintBanner
      self.privilegedFileBanner = privilegedFileBanner
    }
  }

  /// The §5.4 durable-approval prompt: a reason-keyed headline, the taint banner, the
  /// fully-resolved target, blast radius, the privileged-file banner, a size-capped
  /// secret-redacted preview, and scan warnings — assembled in a fixed order so the owner can
  /// judge risk at a glance.
  public static func text(for input: Input) -> String {
    let recorded = input.recorded
    var lines: [String] = [headline(tool: recorded.tool, reason: recorded.reason)]

    if input.taintBanner {
      lines.append(taintBannerText)
    }
    // Fully resolved, never truncated (FR-T5): absolute path after symlink/`..` resolution, or
    // the full URL including query.
    lines.append("Target: \(recorded.canonicalTarget)")
    lines.append("Effect: \(recorded.presentation.blastRadius)")

    if input.privilegedFileBanner {
      lines.append(privilegedFileBannerText)
    }

    if let preview = recorded.presentation.contentPreview {
      lines.append("Preview:")
      lines.append(preview)
    }

    for warning in recorded.presentation.warnings {
      lines.append("⚠ \(warning)")
    }

    lines.append("Tap Approve to allow this one action, or Deny to cancel.")

    return lines.joined(separator: "\n")
  }

  /// The retired Inc 3b ephemeral trifecta prompt (§9.2), still rendered by `TurnRunner`'s
  /// pending-approval path (`TurnRunner.swift:212`) until Task 24 deletes the ephemeral flow. Kept
  /// exhaustive over `ApprovalReason` so it compiles alongside the durable renderer.
  public static func text(for request: ToolApprovalRequest) -> String {
    switch request.reason {
    case .exfilTrifecta:
      """
      ⚠ I want to fetch
      \(request.action.target)
      This session has read external content and holds private data.
      Reply yes to allow this one fetch; anything else cancels.
      """
    case .askTier:
      """
      ⚠ I want to run \(request.action.tool) on
      \(request.action.target)
      This action changes state and needs your explicit approval.
      """
    }
  }
}

// MARK: - Prompt Composition

private extension ToolApprovalPrompt {
  static let taintBannerText =
    "⚠ TAINT: this turn read external/untrusted content — inspect the target before approving."
  static let privilegedFileBannerText =
    "⚠ PRIVILEGED FILE: this path feeds my system prompt / private-data tier."

  static func headline(tool: String, reason: ApprovalReason) -> String {
    switch reason {
    case .askTier:
      "⚠ I want to run \(tool). This changes state and needs your explicit approval."
    case .exfilTrifecta:
      "⚠ I want to run \(tool) while this session holds private data after reading external content."
    }
  }
}
