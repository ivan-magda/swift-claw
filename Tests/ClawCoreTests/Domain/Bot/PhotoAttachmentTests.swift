import Foundation
import Testing

@testable import ClawCore

@Suite struct PhotoAttachmentTests {
  private func size(
    _ fileId: String,
    _ width: Int,
    _ height: Int,
    bytes: Int64?
  ) -> PhotoSize {
    PhotoSize(
      fileId: fileId,
      fileUniqueId: "uniq-\(fileId)",
      width: width,
      height: height,
      fileSizeBytes: bytes
    )
  }

  @Test func picksTheLargestRungThatFitsTheBudget() throws {
    // given — Telegram's ladder, deliberately NOT in ascending order
    let attachment = PhotoAttachment(sizes: [
      size("y", 1280, 960, bytes: 200_000),
      size("s", 90, 67, bytes: 1_500),
      size("w", 2560, 1920, bytes: 900_000),
      size("x", 800, 600, bytes: 80_000),
    ])

    // when
    let chosen = try #require(attachment.best(withinBytes: 512_000))

    // then — the 2560 rung is over budget, so the 1280 rung wins on pixels
    #expect(chosen.fileId == "y")
  }

  @Test func treatsAbsentFileSizeAsEligible() throws {
    // given — Telegram omits file_size when it is zero, so nil must not disqualify a rung
    let attachment = PhotoAttachment(sizes: [
      size("x", 800, 600, bytes: 80_000),
      size("y", 1280, 960, bytes: nil),
    ])

    // when
    let chosen = try #require(attachment.best(withinBytes: 512_000))

    // then
    #expect(chosen.fileId == "y")
  }

  @Test func fallsBackToLargestWhenEveryRungIsOverBudget() throws {
    // given — a hostile or unusual ladder where nothing fits
    let attachment = PhotoAttachment(sizes: [
      size("w", 2560, 1920, bytes: 900_000),
      size("y", 1280, 960, bytes: 700_000),
    ])

    // when — the transport cap is the ground truth, so selection must still return something
    let chosen = try #require(attachment.best(withinBytes: 512_000))

    // then
    #expect(chosen.fileId == "w")
  }

  @Test func emptyLadderSelectsNothing() {
    // given
    let attachment = PhotoAttachment(sizes: [])

    // when
    let chosen = attachment.best(withinBytes: 512_000)

    // then
    #expect(chosen == nil)
  }
}
