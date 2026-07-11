import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ToolApprovalPromptTests {
  private func recorded(
    tool: String,
    target: String,
    reason: ApprovalReason,
    blastRadius: String,
    preview: String? = nil,
    warnings: [String] = []
  ) -> RecordedToolAction {
    RecordedToolAction(
      tool: tool,
      canonicalArgsJSON: "{}",
      argsHash: "hash16hash16hash",
      canonicalTarget: target,
      reason: reason,
      presentation: ToolApprovalPresentation(
        blastRadius: blastRadius,
        contentPreview: preview,
        warnings: warnings
      )
    )
  }

  @Test func codeExecutionReasonGetsDedicatedOwnerCopy() {
    // given
    let input = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "execute_code",
        target: "code_exec:python:0123456789abcdef",
        reason: .codeExec,
        blastRadius: "run python · egress: no · 4 CPU / 1024 MiB"
      ),
      taintBanner: false,
      privilegedFileBanner: false
    )

    // when
    let text = ToolApprovalPrompt.text(for: input)

    // then
    #expect(text.contains("execute_code"))
    #expect(text.contains("disposable sandbox"))
    #expect(text.contains("code_exec:python:0123456789abcdef"))
  }

  @Test func richPromptCarriesToolFullTargetAndBlastRadius() {
    // given
    let input = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "file_write",
        target: "/workspace/notes/plan.md",
        reason: .askTier,
        blastRadius: "create, 1.2 KB"
      ),
      taintBanner: false,
      privilegedFileBanner: false
    )

    // when
    let text = ToolApprovalPrompt.text(for: input)

    // then — structural fields only (TESTING §7.2): tool, fully-resolved target, blast radius
    #expect(text.contains("file_write"))
    #expect(text.contains("/workspace/notes/plan.md"))
    #expect(text.contains("create, 1.2 KB"))
  }

  @Test func fullyResolvedUrlTargetIsNeverTruncated() {
    // given — a long URL with a query string (§5.4: full URL, never model-truncated)
    let target = "https://example.com/a/b/c?token=abcdefghijklmnop&next=2&page=3"
    let input = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "web_fetch",
        target: target,
        reason: .exfilTrifecta,
        blastRadius: "egress to example.com"
      ),
      taintBanner: true,
      privilegedFileBanner: false
    )

    // when
    let text = ToolApprovalPrompt.text(for: input)

    // then
    #expect(text.contains(target))
  }

  @Test func taintBannerAppearsOnlyWhenSet() {
    // given
    let withTaint = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "file_write",
        target: "/w/a.md",
        reason: .askTier,
        blastRadius: "create, 3 B"
      ),
      taintBanner: true,
      privilegedFileBanner: false
    )
    let withoutTaint = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "file_write",
        target: "/w/a.md",
        reason: .askTier,
        blastRadius: "create, 3 B"
      ),
      taintBanner: false,
      privilegedFileBanner: false
    )

    // when / then — the TAINT marker is present exactly when the originating turn ingested
    // untrusted content
    #expect(ToolApprovalPrompt.text(for: withTaint).contains("TAINT"))
    #expect(ToolApprovalPrompt.text(for: withoutTaint).contains("TAINT") == false)
  }

  @Test func privilegedFileBannerAppearsOnlyWhenSet() {
    // given
    let privileged = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "file_write",
        target: "/w/MEMORY.md",
        reason: .askTier,
        blastRadius: "overwrite, 40 B"
      ),
      taintBanner: false,
      privilegedFileBanner: true
    )
    let ordinary = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "file_write",
        target: "/w/notes.md",
        reason: .askTier,
        blastRadius: "overwrite, 40 B"
      ),
      taintBanner: false,
      privilegedFileBanner: false
    )

    // when / then — §5.4 privileged-file warning (SOUL/AGENTS/USER/MEMORY .md)
    #expect(ToolApprovalPrompt.text(for: privileged).contains("PRIVILEGED"))
    #expect(ToolApprovalPrompt.text(for: ordinary).contains("PRIVILEGED") == false)
  }

  @Test func contentPreviewRendersWhenPresentAndIsOmittedWhenNil() {
    // given — the preview is already size-capped + secret-redacted by the tool (§5.4)
    let withPreview = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "file_write",
        target: "/w/a.md",
        reason: .askTier,
        blastRadius: "create, 5 B",
        preview: "hello"
      ),
      taintBanner: false,
      privilegedFileBanner: false
    )
    let withoutPreview = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "web_fetch",
        target: "https://x.example/y",
        reason: .exfilTrifecta,
        blastRadius: "egress to x.example",
        preview: nil
      ),
      taintBanner: true,
      privilegedFileBanner: false
    )

    // when / then
    #expect(ToolApprovalPrompt.text(for: withPreview).contains("hello"))
    #expect(ToolApprovalPrompt.text(for: withoutPreview).contains("Preview") == false)
  }

  @Test func memoryWriteScanWarningsSurfaceInThePrompt() {
    // given
    let input = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "memory_write",
        target: "memory_item:fact:0123456789abcdef",
        reason: .askTier,
        blastRadius: "fact, normal",
        preview: "the note text",
        warnings: ["looks like a secret", "instruction-shaped text"]
      ),
      taintBanner: false,
      privilegedFileBanner: false
    )

    // when
    let text = ToolApprovalPrompt.text(for: input)

    // then — each scan warning is shown so the owner can judge before approving
    #expect(text.contains("looks like a secret"))
    #expect(text.contains("instruction-shaped text"))
  }

  @Test func aShortPromptIsOneKeyboardCarryingChunk() {
    // given
    let input = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "file_write",
        target: "/w/notes.md",
        reason: .askTier,
        blastRadius: "create, 1 B"
      ),
      taintBanner: false,
      privilegedFileBanner: false
    )

    // when
    let chunks = ToolApprovalPrompt.chunks(for: input, chatId: 7, nonce: "n-1")

    // then — the common case: one chunk, keyboard attached, whole prompt as the payload
    #expect(chunks.count == 1)
    #expect(chunks.first?.payload == ToolApprovalPrompt.text(for: input))
    #expect(chunks.first?.stepIndex == 0)
    #expect(chunks.first?.replyMarkup != nil)
  }

  @Test func anOverlongPromptSplitsWithTheKeyboardOnTheFinalChunk() {
    // given — a canonical URL longer than one Telegram message (FR-T5 forbids truncating it, so
    // the prompt must SPLIT instead of producing one undeliverable outbox row)
    let target =
      "https://example.com/?q=" + String(repeating: "a", count: ReplySplitter.limit + 100)
    let input = ToolApprovalPrompt.Input(
      recorded: recorded(
        tool: "web_fetch",
        target: target,
        reason: .exfilTrifecta,
        blastRadius: "egress to example.com"
      ),
      taintBanner: true,
      privilegedFileBanner: false
    )

    // when
    let chunks = ToolApprovalPrompt.chunks(for: input, chatId: 7, nonce: "n-1")

    // then — every chunk is sendable, the full target survives across the split, step indexes are
    // sequential, and ONLY the final chunk (ending with the tap instruction) carries the keyboard
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.payload.count <= ReplySplitter.limit })
    #expect(chunks.map(\.payload).joined() == ToolApprovalPrompt.text(for: input))
    #expect(chunks.map(\.stepIndex) == Array(0..<chunks.count))
    #expect(chunks.dropLast().allSatisfy { $0.replyMarkup == nil })
    #expect(chunks.last?.replyMarkup != nil)
  }

  @Test func richPromptRendersForEveryApprovalReason() {
    // given — the renderer is exhaustive over ApprovalReason; this pins that both reasons produce
    // owner-facing copy carrying the target at runtime (the compile-time guarantee is the switch)
    for reason in [ApprovalReason.askTier, .exfilTrifecta, .codeExec] {
      let input = ToolApprovalPrompt.Input(
        recorded: recorded(
          tool: "file_write",
          target: "/w/target-\(reason.rawValue).md",
          reason: reason,
          blastRadius: "create, 1 B"
        ),
        taintBanner: false,
        privilegedFileBanner: false
      )

      // when
      let text = ToolApprovalPrompt.text(for: input)

      // then
      #expect(text.isEmpty == false)
      #expect(text.contains("/w/target-\(reason.rawValue).md"))
    }
  }
}
