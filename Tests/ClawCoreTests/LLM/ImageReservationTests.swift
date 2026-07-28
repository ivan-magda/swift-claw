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
}
