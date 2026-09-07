import ClawCore
import ClawTestSupport
import Foundation
import Testing

extension CoderServiceFixture {
  static func receipt(launched: Bool) -> CoderProcessReceipt {
    CoderProcessReceipt(
      launchID: UUID(),
      phase: .codex,
      hostBootID: "previous-boot",
      pid: launched ? 123 : nil,
      pgid: launched ? 123 : nil,
      birthIdentity: launched ? "previous-birth" : nil
    )
  }

  func seedUnfinished(receipt: CoderProcessReceipt? = nil) throws -> UUID {
    let id = UUID()
    let origin = CoderOrigin(
      runID: ownerContext.runId,
      sessionID: ownerContext.sessionId,
      requesterUserID: try #require(ownerContext.requesterUserId),
      chatID: ownerContext.chatId,
      toolCallID: ownerContext.toolCallId,
      approvalID: try #require(ownerContext.approvalId)
    )
    let admission = try store.admit(
      id: id,
      prepared: prepared,
      origin: origin,
      maxConcurrentJobs: 4,
      now: Date()
    )
    guard case .admitted = admission else {
      throw CoderError.busy
    }
    if let receipt {
      _ = try store.markRunning(id: id, now: Date())
      try store.recordProcess(id: id, event: .willLaunch(receipt), now: Date())
      if receipt.pid != nil {
        try store.recordProcess(id: id, event: .didLaunch(receipt), now: Date())
      }
    }
    return id
  }
}
