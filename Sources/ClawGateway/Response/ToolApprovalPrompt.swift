import ClawCore
import Foundation

/// The deterministic, gateway-authored approval prompt. Every owner-visible field is
/// authored HERE, never by the model, and the fully-resolved canonical target is never
/// truncated. Delivery-only: joined into the outbox payload, never stored as assistant history.
/// Exhaustive over `ApprovalReason` — a new approval kind cannot compile without owner-facing copy.
public enum ToolApprovalPrompt {
  /// Everything the durable-approval prompt renders. The banners are decided by the suspend
  /// commit from the originating turn's taint state and the target's identity; the
  /// renderer stays a pure function of its input.
  public struct Input: Sendable, Equatable {
    public let recorded: RecordedToolAction
    /// The originating turn ingested untrusted content (TAINT banner).
    public let taintBanner: Bool
    /// The canonical target is a file that steers a later turn (privileged-file banner).
    public let privilegedFileBanner: Bool

    public init(recorded: RecordedToolAction, taintBanner: Bool, privilegedFileBanner: Bool) {
      self.recorded = recorded
      self.taintBanner = taintBanner
      self.privilegedFileBanner = privilegedFileBanner
    }
  }

  /// The durable-approval prompt: a reason-keyed headline, the taint banner, the
  /// fully-resolved target, blast radius, the privileged-file banner, the tool-authored
  /// secret-redacted preview, and scan warnings — assembled in a fixed order so the owner can
  /// judge risk at a glance.
  public static func text(for input: Input) -> String {
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

    lines.append(tapInstruction(reason: recorded.reason))

    return lines.joined(separator: "\n")
  }

  /// The prompt as ready-to-enqueue outbox chunks. One chunk in the common case; a prompt that
  /// exceeds a single Telegram message (a never-truncated URL can be arbitrarily long)
  /// splits grapheme-safely instead of parking one undeliverable row that would stall the shared
  /// outbox. The inline keyboard rides the FINAL chunk — the one ending with the tap instruction —
  /// and the suspend commit stamps `approval_id` onto exactly that keyboard-carrying chunk
  /// (`enqueuePromptChunks`), so button disarm keeps working across a split.
  public static func chunks(for input: Input, chatId: Int64, nonce: String) -> [OutboxChunk] {
    let parts = chunkPayloads(for: text(for: input))
    return parts.enumerated().map { index, payload in
      OutboxChunk(
        stepIndex: index,
        chatId: chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload),
        approvalId: nil,
        replyMarkup: index == parts.count - 1
          ? ApprovalKeyboard.markup(
            nonce: nonce,
            offersTurnWindow: input.recorded.reason.offersTurnScopedWindow
          ) : nil
      )
    }
  }
}

// MARK: - Prompt Composition

private extension ToolApprovalPrompt {
  static let taintBannerText =
    "⚠ TAINT: this turn read external/untrusted content — inspect the target before approving."
  static let privilegedFileBannerText =
    "⚠ PRIVILEGED FILE: this path feeds my system prompt / private-data tier."
  static let splitFencePrefix = "```\n"
  static let splitFenceSuffix = "\n```"

  /// Telegram renders every outbox row as an independent Markdown document. An overlong prompt
  /// containing a fenced preview therefore becomes plain fenced text per row, with command-authored
  /// backticks made visible before splitting; no middle row can inherit an opening fence from the
  /// previous message or expose preview text as active Markdown.
  static func chunkPayloads(for text: String) -> [String] {
    let ordinaryParts = ReplySplitter.split(text: text)
    guard ordinaryParts.count > 1, text.contains("```") else {
      return ordinaryParts
    }

    let visibleText = OwnerDisplaySanitizer.renderMarkdownCodeFenceContent(in: text)
    let contentLimit = ReplySplitter.limit - splitFencePrefix.count - splitFenceSuffix.count
    return ReplySplitter.split(text: visibleText, limit: contentLimit).map { part in
      splitFencePrefix + part + splitFenceSuffix
    }
  }

  static func headline(tool: String, reason: ApprovalReason) -> String {
    switch reason {
    case .askTier:
      "⚠ I want to run \(tool). This changes state and needs your explicit approval."
    case .exfilTrifecta:
      "⚠ I want to run \(tool) while this session holds private data after reading external content."
    case .codeExec:
      "⚠ I want to run \(tool) in a disposable sandbox. Review the complete script and staged inputs before approving."
    case .hostShell:
      "⚠ I want to run \(tool) on your machine, outside any sandbox. Read the exact command before approving."
    }
  }

  /// The closing instruction names every button the keyboard actually draws, so the copy and the
  /// markup cannot disagree about what a tap does.
  static func tapInstruction(reason: ApprovalReason) -> String {
    guard reason.offersTurnScopedWindow else {
      return "Tap Approve to allow this one action, or Deny to cancel."
    }
    return
      "Tap Approve to allow this one action, Approve for this turn to stop asking until this "
      + "turn ends, or Deny to cancel."
  }
}
