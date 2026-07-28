import Foundation
import Testing

@testable import ClawCore

@Suite struct ImagePartTests {
  @Test func sniffsEachSupportedFormatFromItsMagicBytes() {
    // given — the leading bytes each format is identified by
    let samples: [(Data, ImageMediaType)] = [
      (Data([0xFF, 0xD8, 0xFF, 0xE0]), .jpeg),
      (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), .png),
      (Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), .gif),
      (Data("RIFF____WEBPVP8 ".utf8), .webp),
    ]

    // when / then
    for (bytes, expected) in samples {
      #expect(ImageMediaType.sniff(bytes) == expected)
    }
  }

  @Test func rejectsBytesThatAreNotAnImage() {
    // given — a plausible-looking but non-image payload, and a truncated header
    let html = Data("<!DOCTYPE html>".utf8)
    let truncated = Data([0xFF, 0xD8])

    // when / then
    #expect(ImageMediaType.sniff(html) == nil)
    #expect(ImageMediaType.sniff(truncated) == nil)
  }

  @Test func rejectsRiffThatIsNotWebp() {
    // given — RIFF also fronts WAV and AVI
    let wav = Data("RIFF____WAVEfmt ".utf8)

    // when / then
    #expect(ImageMediaType.sniff(wav) == nil)
  }

  @Test func visualTokenEstimateUsesThePatchGridAndIsCapped() {
    // given — the published 28px patch grid, and an image far past the cap
    let typical = ImagePart(data: Data(), mediaType: .jpeg, width: 1280, height: 960)
    let huge = ImagePart(data: Data(), mediaType: .jpeg, width: 8000, height: 8000)

    // when / then — ceil(1280/28) * ceil(960/28) == 46 * 35
    #expect(typical.visualTokenEstimate == 1_610)
    #expect(huge.visualTokenEstimate == ImageBounds.maximumVisualTokens)
  }
}
