import Foundation
import Testing

@testable import ClawCore

@Suite struct FrontmatterFenceTests {
  @Test func splitsFrontmatterFromBody() {
    // given
    let text = """
      ---
      name: summarize
      description: Summarize text.
      ---
      # Summarize

      Step one.
      """

    // when
    let document = FrontmatterFence.split(text)

    // then
    #expect(document?.frontmatter == "name: summarize\ndescription: Summarize text.")
    #expect(document?.body == "# Summarize\n\nStep one.")
  }

  @Test func crlfLineEndingsSplitAtTheSameFences() {
    // given — an editor that writes CRLF leaves "\r" on every trimmed fence line
    let text = "---\r\nname: summarize\r\n---\r\nBody line.\r\n"

    // when
    let document = FrontmatterFence.split(text)

    // then
    #expect(document?.frontmatter == "name: summarize\r")
    #expect(document?.body == "Body line.")
  }

  @Test func fencesWithTrailingWhitespaceStillClose() {
    // given
    let text = "---  \nname: summarize\n---\t\nBody line."

    // when
    let document = FrontmatterFence.split(text)

    // then
    #expect(document?.body == "Body line.")
  }

  @Test func horizontalRuleInsideTheBodyStaysInTheBody() {
    // given — the closing fence is the FIRST one after the opener; later rules are content
    let text = """
      ---
      name: summarize
      ---
      Intro.

      ---

      Outro.
      """

    // when
    let document = FrontmatterFence.split(text)

    // then
    #expect(document?.frontmatter == "name: summarize")
    #expect(document?.body == "Intro.\n\n---\n\nOutro.")
  }

  @Test func emptyBodyAfterTheClosingFenceIsEmptyNotNil() {
    // given
    let text = "---\nname: summarize\n---\n"

    // when
    let document = FrontmatterFence.split(text)

    // then
    #expect(document?.body.isEmpty == true)
  }

  @Test func missingOpeningOrClosingFenceYieldsNil() {
    // given
    let noOpener = "name: summarize\n---\nBody."
    let noCloser = "---\nname: summarize\nBody."
    let leadingBlankLine = "\n---\nname: summarize\n---\nBody."

    // when / then — a document that lost a fence has no identifiable body
    #expect(FrontmatterFence.split(noOpener) == nil)
    #expect(FrontmatterFence.split(noCloser) == nil)
    #expect(FrontmatterFence.split(leadingBlankLine) == nil)
    #expect(FrontmatterFence.split("") == nil)
  }
}
