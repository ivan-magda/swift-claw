import ClawCore
import Testing

@testable import ClawGateway

@Suite struct ApprovalKeyboardTests {
  private static let malformedCallbacks: [String] = [
    "",  // empty
    "apr:",  // no nonce, no verdict
    "apr:nonce",  // two parts
    "apr:nonce:y:extra",  // four parts
    "xyz:nonce:y",  // wrong prefix
    "nonce:y",  // missing prefix entirely
    "apr::y",  // empty nonce
    "apr:nonce:Y",  // wrong-case verdict
    "apr:nonce:yes",  // verbose verdict
    "apr:nonce:z",  // unknown verdict
    "apr:no:nce:y",  // a colon inside the nonce region — never valid base64url
  ]

  @Test func callbackDataUsesThePinnedFraming() {
    // given / when
    let approve = ApprovalKeyboard.callbackData(
      nonce: "AbC-1_dEfG",
      verdict: .approve
    )
    let deny = ApprovalKeyboard.callbackData(
      nonce: "AbC-1_dEfG",
      verdict: .deny
    )

    // then — "apr:<nonce>:y" | "apr:<nonce>:n" (spec §4.6/§5.4)
    #expect(approve == "apr:AbC-1_dEfG:y")
    #expect(deny == "apr:AbC-1_dEfG:n")
  }

  @Test func callbackDataStaysUnderTelegramsSixtyFourByteCap() {
    // given — a real 22-char base64url nonce is the production width
    let nonce = ApprovalNonce.generate()

    // when
    let approve = ApprovalKeyboard.callbackData(
      nonce: nonce,
      verdict: .approve
    )
    let deny = ApprovalKeyboard.callbackData(nonce: nonce, verdict: .deny)

    // then — the framing must never overflow Telegram's callback_data cap (spec §4.6)
    #expect(approve.utf8.count <= 64)
    #expect(deny.utf8.count <= 64)
  }

  @Test func parseRoundTripsBothVerdicts() {
    // given
    let nonce = "AbC-1_dEfG"

    // when
    let approve = ApprovalKeyboard.parse(
      ApprovalKeyboard.callbackData(nonce: nonce, verdict: .approve)
    )
    let deny = ApprovalKeyboard.parse(
      ApprovalKeyboard.callbackData(nonce: nonce, verdict: .deny)
    )

    // then — the nonce survives verbatim; each verdict maps to its own case
    #expect(approve?.nonce == nonce)
    #expect(approve?.verdict == .approve)
    #expect(deny?.nonce == nonce)
    #expect(deny?.verdict == .deny)
  }

  @Test func theTurnScopedVerdictRoundTripsUnderTheSameFraming() {
    // given — a real 22-char base64url nonce is the production width
    let nonce = ApprovalNonce.generate()

    // when
    let data = ApprovalKeyboard.callbackData(nonce: nonce, verdict: .approveForTurn)

    // then — a third verdict must not push the framing past Telegram's callback_data cap
    #expect(data == "apr:\(nonce):t")
    #expect(data.utf8.count <= 64)
    #expect(ApprovalKeyboard.parse(data)?.verdict == .approveForTurn)
  }

  @Test func onlyAWindowOfferingPromptDrawsTheThirdButton() {
    // given
    let nonce = "AbC-1_dEfG"

    // when
    let plain = ApprovalKeyboard.markup(nonce: nonce)
    let offering = ApprovalKeyboard.markup(nonce: nonce, offersTurnWindow: true)

    // then — the turn verdict is tappable only where the prompt offered it, and the other two
    // buttons keep their framing and order
    #expect(plain.contains("apr:AbC-1_dEfG:t") == false)
    #expect(offering.contains("apr:AbC-1_dEfG:t"))
    #expect(offering.contains("Approve for this turn"))
    for markup in [plain, offering] {
      #expect(markup.contains("apr:AbC-1_dEfG:y"))
      #expect(markup.contains("apr:AbC-1_dEfG:n"))
    }
  }

  @Test(arguments: malformedCallbacks)
  func parseStrictlyRejectsMalformedData(_ callbackData: String) {
    // given / when / then — anything not "apr:<nonce>:y|n" is dropped before the §6.2 auth chain
    #expect(ApprovalKeyboard.parse(callbackData) == nil)
  }

  @Test func markupIsDeterministicAndCarriesBothCallbacks() {
    // given
    let nonce = "AbC-1_dEfG"

    // when — no Date, no randomness: the same input renders byte-identical markup
    let first = ApprovalKeyboard.markup(nonce: nonce)
    let second = ApprovalKeyboard.markup(nonce: nonce)

    // then
    #expect(first == second)
    #expect(first.contains("apr:AbC-1_dEfG:y"))
    #expect(first.contains("apr:AbC-1_dEfG:n"))
    #expect(first.contains("\"inline_keyboard\""))
  }

  @Test func markupEmbedsCallbacksThatParseAccepts() {
    // given — a real nonce, to prove the button data the client echoes back is exactly what
    // parse validates (the suspend→callback round trip closes here)
    let nonce = ApprovalNonce.generate()

    // when
    let markup = ApprovalKeyboard.markup(nonce: nonce)

    // then
    #expect(
      markup.contains(
        ApprovalKeyboard.callbackData(nonce: nonce, verdict: .approve)
      )
    )
    let approve = ApprovalKeyboard.parse(
      ApprovalKeyboard.callbackData(nonce: nonce, verdict: .approve)
    )
    #expect(approve?.nonce == nonce)
    #expect(approve?.verdict == .approve)
  }
}
