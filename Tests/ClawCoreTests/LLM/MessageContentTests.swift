import Foundation
import Testing

@testable import ClawCore

@Suite struct MessageContentTests {
  private let pixel = ImagePart(
    data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
    mediaType: .jpeg,
    width: 1280,
    height: 960
  )

  @Test func stringInitProducesASinglePlainTextPart() {
    // given / when
    let content = MessageContent("hello")

    // then — plain text must stay distinguishable so the wire keeps encoding it as a JSON string
    #expect(content.parts == [.text("hello")])
    #expect(content.text == "hello")
    #expect(content.isPlainText)
    #expect(content.images.isEmpty)
  }

  @Test func textAccessorJoinsTextPartsAndIgnoresImages() {
    // given
    let content = MessageContent(parts: [.image(pixel), .text("what is this?")])

    // when / then — the grapheme-based context fitter reads this and must not see image bytes
    #expect(content.text == "what is this?")
    #expect(content.isPlainText == false)
    #expect(content.images == [pixel])
  }

  @Test func chatMessageStillAcceptsAPlainString() {
    // given / when — the compatibility guarantee for every existing construction site
    let message = ChatMessage(role: .user, content: "hi")

    // then
    #expect(message.content == MessageContent("hi"))
  }
}
