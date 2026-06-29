import Foundation
import Testing

@testable import ClawCore

@Suite struct MemoryWriteRequestTests {
  @Test func normalizesStoredTextToNFC() throws {
    // given
    let decomposed = "cafe\u{0301}"
    let expectedScalars = Array("caf\u{00E9}".unicodeScalars)

    // when
    let request = try MemoryWriteBuilder.build(
      rawText: decomposed,
      kind: .user,
      sessionId: 12
    )

    // then
    #expect(Array(request.item.text.unicodeScalars) == expectedScalars)
    #expect(request.confirmationText.contains("caf\u{00E9}"))
  }

  @Test func stripsInvisibleAndBidiControlsFromStoredTextButShowsThemForConfirm() throws {
    // given
    let rawText = "alpha\u{200B}beta\u{202E}gamma"

    // when
    let request = try MemoryWriteBuilder.build(
      rawText: rawText,
      kind: .project,
      sessionId: nil
    )

    // then
    #expect(request.item.text == "alphabetagamma")
    #expect(request.confirmationText.contains("<U+200B>"))
    #expect(request.confirmationText.contains("<U+202E>"))
  }

  @Test func emptyAfterNormalizationIsRejected() {
    // given
    let rawText = "\u{200B}\u{202E}   "

    // when / then
    #expect(throws: MemoryWriteBuildError.emptyAfterNormalization) {
      try MemoryWriteBuilder.build(rawText: rawText, kind: .user, sessionId: nil)
    }
  }

  @Test func patternScanWarnsButDoesNotBlock() throws {
    // given
    let rawText = "My token is sk-test and this is still owner-confirmed."

    // when
    let request = try MemoryWriteBuilder.build(
      rawText: rawText,
      kind: .reference,
      sessionId: 99
    )

    // then
    #expect(request.item.text == rawText)
    #expect(request.warnings.contains(.possibleSecret))
    #expect(request.confirmationText.contains("Warnings: possible secret-shaped text"))
  }

  @Test func buildsOwnerNormalImportanceMemoryItem() throws {
    // given / when
    let request = try MemoryWriteBuilder.build(
      rawText: "prefers focused implementation plans",
      kind: .feedback,
      sessionId: 5
    )

    // then
    #expect(request.item.kind == .feedback)
    #expect(request.item.sensitivity == .normal)
    #expect(request.item.importance == .normal)
    #expect(request.item.source == .owner)
    #expect(request.item.sessionId == 5)
  }
}
