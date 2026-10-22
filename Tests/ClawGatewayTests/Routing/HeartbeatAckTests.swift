import Foundation
import Testing

@testable import ClawGateway

@Suite
struct HeartbeatAckTests {
  @Test
  func tokenAloneIsAnAck() {
    // given / when / then
    #expect(HeartbeatAck.isAck("HEARTBEAT_OK"))
    #expect(HeartbeatAck.isAck("  HEARTBEAT_OK\n"))
  }

  @Test
  func tokenWithShortTailIsAnAck() {
    // given — model politeness around the token stays an ack
    let content = "HEARTBEAT_OK\nAll checks passed, nothing needs you."

    // when / then
    #expect(HeartbeatAck.isAck(content))
  }

  @Test
  func leadingAndTrailingTokensBothStrip() {
    // given — the remainder fits the cap only once BOTH markers are stripped (313 chars with one)
    let content = "HEARTBEAT_OK " + String(repeating: "x", count: 300) + " HEARTBEAT_OK"

    // when / then
    #expect(HeartbeatAck.isAck(content))
  }

  @Test
  func threeHundredCharRemainderIsTheBoundary() {
    // given — the pinned threshold: ≤ 300 chars of remainder suppresses, 301 delivers
    let exactlyAtCap = "HEARTBEAT_OK " + String(repeating: "x", count: 300)
    let oneOver = "HEARTBEAT_OK " + String(repeating: "x", count: 301)

    // when / then
    #expect(HeartbeatAck.isAck(exactlyAtCap))
    #expect(HeartbeatAck.isAck(oneOver) == false)
  }

  @Test
  func tokenlessShortTextIsNotAnAck() {
    // given — a concise heartbeat reply WITHOUT the token is owner-relevant (an opt-in alert), so
    // it must deliver, never suppress. Only the HEARTBEAT_OK marker authorizes silent drop.
    #expect(HeartbeatAck.isAck("All good.") == false)
  }

  @Test
  func embeddedTokenDoesNotStrip() {
    // given — only ONE leading and ONE trailing token strip; an embedded token is content, so no
    // token is present as a leading/trailing marker here — this is not an ack. The tail is short,
    // so only the missing marker (not the length cap) can make this false.
    let content = "prefix HEARTBEAT_OK suffix"

    // when / then
    #expect(HeartbeatAck.isAck(content) == false)
  }

  @Test
  func nearTokenPrefixIsNotAnAck() {
    // given — a malformed near-token alert (HEARTBEAT_OKAY…) must NOT be treated as the ack
    // token; its substantive tail must deliver, not be silently suppressed (P2 fix).
    #expect(HeartbeatAck.isAck("HEARTBEAT_OKAY: backup failed") == false)
  }

  @Test
  func nearTokenSuffixIsNotAnAck() {
    // given — a word ending in the token bytes without a boundary is not the trailing marker
    #expect(HeartbeatAck.isAck("status: allHEARTBEAT_OK") == false)
  }
}
