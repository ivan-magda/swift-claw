import Foundation
import Testing

@testable import ClawGateway

@Suite struct HeartbeatAckTests {
  @Test func tokenAloneIsAnAck() {
    // given / when / then
    #expect(HeartbeatAck.isAck("HEARTBEAT_OK"))
    #expect(HeartbeatAck.isAck("  HEARTBEAT_OK\n"))
  }

  @Test func tokenWithShortTailIsAnAck() {
    // given — model politeness around the token stays an ack
    let content = "HEARTBEAT_OK\nAll checks passed, nothing needs you."

    // when / then
    #expect(HeartbeatAck.isAck(content))
  }

  @Test func leadingAndTrailingTokensBothStrip() {
    // given
    let content = "HEARTBEAT_OK all quiet HEARTBEAT_OK"

    // when / then
    #expect(HeartbeatAck.isAck(content))
  }

  @Test func threeHundredCharRemainderIsTheBoundary() {
    // given — the pinned threshold: ≤ 300 chars of remainder suppresses, 301 delivers
    let exactlyAtCap = "HEARTBEAT_OK " + String(repeating: "x", count: 300)
    let oneOver = "HEARTBEAT_OK " + String(repeating: "x", count: 301)

    // when / then
    #expect(HeartbeatAck.maxAckChars == 300)
    #expect(HeartbeatAck.isAck(exactlyAtCap))
    #expect(HeartbeatAck.isAck(oneOver) == false)
  }

  @Test func longSubstantiveTextIsNotAnAck() {
    // given
    let report = String(repeating: "the backup target disk is failing — ", count: 12)

    // when / then
    #expect(HeartbeatAck.isAck(report) == false)
  }

  @Test func tokenlessShortTextIsNotAnAck() {
    // given — a concise heartbeat reply WITHOUT the token is owner-relevant (an opt-in alert), so
    // it must deliver, never suppress. Only the HEARTBEAT_OK marker authorizes silent drop.
    #expect(HeartbeatAck.isAck("All good.") == false)
  }

  @Test func embeddedTokenDoesNotStrip() {
    // given — only ONE leading and ONE trailing token strip; an embedded token is content, so no
    // token is present as a leading/trailing marker here — this is not an ack.
    let content = "prefix HEARTBEAT_OK " + String(repeating: "y", count: 300)

    // when / then
    #expect(HeartbeatAck.isAck(content) == false)
  }
}
