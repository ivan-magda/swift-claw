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
}
