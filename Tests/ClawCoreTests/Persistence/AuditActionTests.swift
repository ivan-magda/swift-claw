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
}
