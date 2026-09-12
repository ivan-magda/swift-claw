import ClawCore
import Foundation

/// The deterministic, gateway-authored approval prompt. Every owner-visible field is
/// authored HERE, never by the model, and the fully-resolved canonical target is never
/// truncated. Delivery-only: joined into the outbox payload, never stored as assistant history.
/// Exhaustive over `ApprovalReason` — a new approval kind cannot compile without owner-facing copy.
enum ToolApprovalPrompt {
  /// Everything the durable-approval prompt renders. The banners are decided by the suspend
  /// commit from the originating turn's taint state and the target's identity; the
  /// renderer stays a pure function of its input.
  struct Input: Sendable, Equatable {
    let recorded: RecordedToolAction
    /// The originating turn ingested untrusted content (TAINT banner).
    let taintBanner: Bool
    /// The canonical target is a file that steers a later turn (privileged-file banner).
    let privilegedFileBanner: Bool
    let isGroup: Bool

    init(
      recorded: RecordedToolAction,
      taintBanner: Bool,
      privilegedFileBanner: Bool,
      isGroup: Bool = false
    ) {
      self.recorded = recorded
      self.taintBanner = taintBanner
      self.privilegedFileBanner = privilegedFileBanner
      self.isGroup = isGroup
    }
  }

  /// The durable-approval prompt: a reason-keyed headline, the taint banner, the
  /// fully-resolved target, blast radius, the privileged-file banner, the tool-authored
  /// secret-redacted preview, and scan warnings — assembled in a fixed order so the owner can
  /// judge risk at a glance.
  static func text(for input: Input) -> String {
    if input.recorded.reason == .coderSubmit {
      return coderText(for: input)
    }
    let recorded = input.recorded
    var lines: [String] = [headline(tool: recorded.tool, reason: recorded.reason)]

    if input.taintBanner {
      lines.append(taintBannerText)
    }
    // Fully resolved, never truncated: absolute path after symlink/`..` resolution, or
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

  /// The prompt as ready-to-enqueue outbox chunks. One chunk in the common case; a prompt that
  /// exceeds a single Telegram message (a never-truncated URL can be arbitrarily long)
  /// splits grapheme-safely instead of parking one undeliverable row that would stall the shared
  /// outbox. The inline keyboard rides the FINAL chunk — the one ending with the tap instruction —
  /// and the suspend commit stamps `approval_id` onto exactly that keyboard-carrying chunk
  /// (`enqueuePromptChunks`), so button disarm keeps working across a split.
  static func chunks(for input: Input, chatId: Int64, nonce: String) -> [OutboxChunk] {
    let prompt = text(for: input)
    let parts =
      input.recorded.reason == .coderSubmit
      ? CoderCardMarkdown.split(text: prompt) : ReplySplitter.split(text: prompt)
    return parts.enumerated().map { index, payload in
      OutboxChunk(
        stepIndex: index,
        chatId: chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload),
        approvalId: nil,
        replyMarkup: index == parts.count - 1 ? ApprovalKeyboard.markup(nonce: nonce) : nil
      )
    }
  }
}

// MARK: - Prompt Composition

private extension ToolApprovalPrompt {
  static func coderText(for input: Input) -> String {
    let recorded = input.recorded
    var blocks = [
      "## Coder approval",
      "Delegate this task to native Codex. Review the complete task and publication scope.",
    ]
    if input.taintBanner {
      blocks.append(taintBannerText)
    }
    if input.privilegedFileBanner {
      blocks.append(privilegedFileBannerText)
    }
    blocks.append(recorded.presentation.blastRadius)
    if let preview = recorded.presentation.contentPreview {
      blocks.append(preview)
    }
    for warning in recorded.presentation.warnings {
      blocks.append(CoderCardMarkdown.field("⚠ Native access", warning))
    }
    if input.isGroup {
      blocks.append("Any member of this group can approve or deny this one action.")
    }
    blocks.append("Tap Approve to allow this one action, or Deny to cancel.")
    return blocks.joined(separator: "\n\n")
  }

  static let taintBannerText =
    "⚠ TAINT: this turn read external/untrusted content — inspect the target before approving."
  static let privilegedFileBannerText =
    "⚠ PRIVILEGED FILE: this path feeds my system prompt / private-data tier."

  static func headline(tool: String, reason: ApprovalReason) -> String {
    switch reason {
    case .askTier:
      "⚠ I want to run \(tool). This changes state and needs your explicit approval."
    case .exfilTrifecta:
      """
      ⚠ I want to run \(tool) while this session holds private data \
      after reading external content.
      """
    case .coderSubmit:
      """
      ⚠ I want to delegate \(tool) to your native Codex installation \
      and its configured integrations. \
      Review the workspace and publication scope before approving.
      """
    case .codeExec:
      """
      ⚠ I want to run \(tool) in a disposable sandbox. \
      Review the complete script and staged inputs before approving.
      """
    }
  }
}
