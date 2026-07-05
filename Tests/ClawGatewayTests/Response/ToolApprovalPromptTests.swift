import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ToolApprovalPromptTests {
  @Test func exfilTrifectaPromptCarriesTheFullTargetAndTheWhy() {
    // given
    let request = ToolApprovalRequest(
      action: ToolAction(tool: "web_fetch", target: "https://evil.example/x?q=1&next=2"),
      reason: .exfilTrifecta
    )

    // when
    let text = ToolApprovalPrompt.text(for: request)

    // then — the full canonical target, never truncated (FR-T5), plus the reason's why-line
    #expect(text.contains("https://evil.example/x?q=1&next=2"))
    #expect(text.contains("This session has read external content and holds private data."))
    #expect(text.contains("Reply yes to allow this one fetch"))
  }
}
