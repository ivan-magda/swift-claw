import Testing

@testable import ClawGateway

@Suite struct UnauthorizedStartTextTests {
  @Test func refusalCarriesACopyPasteableAllowlistLine() {
    // given
    let userId: Int64 = 12_345_678

    // when
    let text = MessageRouter.unauthorizedStartText(userId: userId)

    // then — the owner can paste the last line into clawd.env verbatim
    #expect(text.contains("This is a private bot."))
    #expect(text.hasSuffix("CLAW_ALLOWLIST=12345678"))
  }
}
