import Foundation
import Testing

@testable import ClawCore

@Suite struct AuditActionTests {
  @Test func memoryActionsHaveStableRawValues() {
    // given / when / then
    #expect(AuditAction.memoryWrite.rawValue == "memory_write")
    #expect(AuditAction.memoryDelete.rawValue == "memory_delete")
  }

  @Test func memoryAuditEventUsesTypedAction() {
    // given
    let event = AuditEvent(
      actor: .owner,
      action: .memoryWrite,
      argsRedacted: "{}",
      sessionId: 42,
      ts: .init(timeIntervalSince1970: 10)
    )

    // then
    #expect(event.action == .memoryWrite)
    #expect(event.action.rawValue == "memory_write")
    #expect(event.sessionId == 42)
  }

  private static let schedulerActions: [(action: AuditAction, rawValue: String)] = [
    (.jobCreated, "job_created"),
    (.jobExecuted, "job_executed"),
    (.jobPaused, "job_paused"),
    (.jobResumed, "job_resumed"),
    (.jobCancelled, "job_cancelled"),
    (.jobFailed, "job_failed"),
    (.jobMisfire, "job_misfire"),
    (.heartbeatFired, "heartbeat_fired"),
    (.heartbeatSuppressed, "heartbeat_suppressed"),
    (.heartbeatSkipped, "heartbeat_skipped"),
  ]

  @Test(arguments: schedulerActions)
  func schedulerActionsHaveStableRawValues(_ fixture: (action: AuditAction, rawValue: String)) {
    // given / when / then — rawValues are the durable audit vocabulary (preamble)
    #expect(fixture.action.rawValue == fixture.rawValue)
  }

  private static let approvalActions: [(action: AuditAction, rawValue: String)] = [
    (.approvalRequested, "approval_requested"),
    (.approvalGranted, "approval_granted"),
    (.approvalDenied, "approval_denied"),
  ]

  @Test(arguments: approvalActions)
  func approvalActionsHaveStableRawValues(_ fixture: (action: AuditAction, rawValue: String)) {
    // given / when / then — rawValues are the durable audit vocabulary (spec §3.1, preamble)
    #expect(fixture.action.rawValue == fixture.rawValue)
  }

  @Test func learningResetVocabularyHasStableTypedRawValues() {
    // given / when / then — duplicated string literals at write sites would let one durable value
    // drift while the other values continue to pass their integration paths.
    #expect(AuditAction.learningReset.rawValue == "learning_reset")
    #expect(LearningTrialCloseReason.learningReset.rawValue == "learning_reset")
    #expect(LearningOperationFailure.staleEpoch.rawValue == "stale_epoch")
    #expect(ResetReceipt.kind == "learning_reset")
  }
}
