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

  @Test func stripsAdditionalBidiAndZeroWidthControlsButShowsThemForConfirm() throws {
    // given
    let rawText = "alpha\u{061C}beta\u{200E}gamma\u{200F}delta\u{2060}omega"

    // when
    let request = try MemoryWriteBuilder.build(
      rawText: rawText,
      kind: .project,
      sessionId: nil
    )

    // then
    #expect(request.item.text == "alphabetagammadeltaomega")
    #expect(request.confirmationText.contains("<U+061C>"))
    #expect(request.confirmationText.contains("<U+200E>"))
    #expect(request.confirmationText.contains("<U+200F>"))
    #expect(request.confirmationText.contains("<U+2060>"))
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

  @Test func defaultsPreserveTheRememberCallSiteVerbatim() throws {
    // given / when — no new arguments: the /remember flow must be byte-identical
    let request = try MemoryWriteBuilder.build(rawText: "likes tea", kind: .user, sessionId: 3)

    // then
    #expect(request.item.source == .owner)
    #expect(request.item.importance == .normal)
    #expect(request.item.sensitivity == .normal)
    #expect(request.confirmationText.contains("Reply yes to save, no to cancel."))
  }

  @Test func parameterizedBuildCarriesSourceImportanceAndSensitivity() throws {
    // given / when — the memory_write call shape (§8.2)
    let request = try MemoryWriteBuilder.build(
      rawText: "prefers metric units",
      kind: .user,
      sessionId: nil,
      source: .assistant,
      importance: .high,
      sensitivity: .high
    )

    // then — normalization and scans are the same code path; only the item fields move
    #expect(request.item.source == .assistant)
    #expect(request.item.importance == .high)
    #expect(request.item.sensitivity == .high)
    #expect(request.item.text == "prefers metric units")
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
