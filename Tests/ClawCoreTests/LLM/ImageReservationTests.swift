import Foundation
import Testing

@testable import ClawCore

@Suite struct ImageReservationTests {
  private func photo(width: Int, height: Int) -> ImagePart {
    ImagePart(
      data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
      mediaType: .jpeg,
      width: width,
      height: height
    )
  }

  @Test func imagesAreReservedEvenOnTheTextOnlyPolicy() {
    // given — a route with no replay state still sends images, so the reservation cannot live
    // inside the replay-state branch
    let messages = [
      ChatMessage(
        role: .user,
        content: MessageContent(parts: [.image(photo(width: 1280, height: 960))])
      )
    ]

    // when
    let reserved = LLMInputReservationPolicy.textOnly.additionalTokens(for: messages)

    // then — ceil(1280/28) * ceil(960/28)
    #expect(reserved == 1_610)
  }

  @Test func everyImageInTheRequestIsCountedIncludingReplayedOnes() {
    // given — one image on the newest message and one carried in from history
    let messages = [
      ChatMessage(
        role: .user,
        content: MessageContent(parts: [.image(photo(width: 1280, height: 960))])
      ),
      ChatMessage(role: .assistant, content: "a rainbow"),
      ChatMessage(
        role: .user,
        content: MessageContent(parts: [.image(photo(width: 800, height: 600))])
      ),
    ]

    // when
    let reserved = LLMInputReservationPolicy.textOnly.additionalTokens(for: messages)

    // then — 46*35 + 29*22
    #expect(reserved == 1_610 + 638)
  }

  @Test func textOnlyRequestsReserveNothing() {
    // given
    let messages = [ChatMessage(role: .user, content: "hi")]

    // when / then
    #expect(LLMInputReservationPolicy.textOnly.additionalTokens(for: messages) == 0)
  }

  /// The route that actually carries replay state is the one shipped for ChatGPT, so the image
  /// charge has to survive alongside the replay charge rather than only on the stateless route.
  @Test func theReplayStateRouteChargesImagesOnTopOfItsReplayReservation() {
    // given — a photo the owner sent, then a reply whose reasoning state is replayed next turn
    let messages = [
      ChatMessage(
        role: .user,
        content: MessageContent(parts: [.image(photo(width: 1280, height: 960))])
      ),
      Self.statefulReply(payloadBytes: 10),
    ]

    // when
    let reserved = LLMInputReservationPolicy.chatGPTReplayState.additionalTokens(for: messages)

    // then — 46*35 for the photo, plus 10 bytes at two tokens each and one framing allowance
    #expect(reserved == 1_610 + 276)
  }

  /// Pins that the two subtotals are combined saturatingly: a plain addition traps here instead of
  /// clamping, and only an image on the same request makes the left operand nonzero.
  @Test func anAlreadySaturatedReplayReservationAbsorbsImagesInsteadOfOverflowing() {
    // given
    let absurd = LLMInputReservationPolicy.replayState(
      tokensPerByte: .max,
      framingTokensPerState: .max,
      aggregateByteCap: 1024
    )
    let messages = [
      ChatMessage(
        role: .user,
        content: MessageContent(parts: [.image(photo(width: 1280, height: 960))])
      ),
      Self.statefulReply(payloadBytes: 8),
    ]

    // when
    let reserved = absurd.additionalTokens(for: messages)

    // then
    #expect(reserved == .max)
  }

  /// Payload bytes are deliberately invalid UTF-8 so any policy that tries to read them fails
  /// loudly rather than quietly agreeing with the byte math.
  private static func statefulReply(payloadBytes: Int) -> ChatMessage {
    ChatMessage(
      role: .assistant,
      content: "reply",
      providerState: ProviderExchangeState(
        issuer: "openai-chatgpt-responses-v1:profile:model:epoch",
        payload: Data(repeating: 0xFF, count: payloadBytes)
      )
    )
  }
}
