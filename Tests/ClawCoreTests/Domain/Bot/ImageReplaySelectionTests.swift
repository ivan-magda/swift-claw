import Foundation
import Testing

@testable import ClawCore

@Suite struct ImageReplaySelectionTests {
  private func photo(bytes: Int) -> ImagePart {
    ImagePart(
      data: Data(repeating: 0xFF, count: bytes),
      mediaType: .jpeg,
      width: 1280,
      height: 960
    )
  }

  @Test func keepsNewestFirstUntilTheAggregateCapIsCrossed() {
    // given — row ids increase monotonically, so the highest id is the newest image
    let images: [Int64: ImagePart] = [
      10: photo(bytes: 400_000),
      20: photo(bytes: 400_000),
      30: photo(bytes: 400_000),
    ]

    // when
    let kept = ImageReplaySelection.affordable(images, aggregateCap: 1_000_000)

    // then — the two newest fit; the oldest is what gets left behind
    #expect(Set(kept.keys) == [20, 30])
  }

  @Test func aSingleOversizedImageIsDroppedRatherThanFailing() {
    // given
    let images: [Int64: ImagePart] = [10: photo(bytes: 2_000_000)]

    // when
    let kept = ImageReplaySelection.affordable(images, aggregateCap: 1_000_000)

    // then — dropping degrades the turn; it never fails it
    #expect(kept.isEmpty)
  }

  @Test func everythingUnderTheCapSurvives() {
    // given
    let images: [Int64: ImagePart] = [10: photo(bytes: 100_000), 20: photo(bytes: 100_000)]

    // when
    let kept = ImageReplaySelection.affordable(images, aggregateCap: 1_000_000)

    // then
    #expect(Set(kept.keys) == [10, 20])
  }

  @Test func stopsAtTheFirstImageThatCrossesTheCapRatherThanSkippingIt() {
    // given — a small ancient image sits behind a large recent one
    let images: [Int64: ImagePart] = [
      10: photo(bytes: 1_000),
      20: photo(bytes: 900_000),
      30: photo(bytes: 900_000),
    ]

    // when
    let kept = ImageReplaySelection.affordable(images, aggregateCap: 1_000_000)

    // then — recency decides, so the older pair is left behind even though 10 would have fit
    #expect(Set(kept.keys) == [30])
  }
}
