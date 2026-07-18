import ClawCore
import Foundation
import Testing

@testable import ClawAppleSpeech

#if canImport(Speech) && canImport(AVFAudio)
  /// The pure end-of-race policy: which transcript (or which typed error) leaves the engine
  /// after every lane ran, collected as candidates or as a remembered first failure.
  @Suite struct LaneSettlementTests {
    @available(macOS 26.0, *)
    @Test func theWinningCandidateSettlesAsItsText() {
      // given
      let winner = ScoredTranscript(text: "привет мир", confidence: 0.84)
      let garbage = ScoredTranscript(text: ", , ,", confidence: 0.02)

      // when
      let outcome = AppleSpeechTranscriber.settle(
        candidates: [garbage, winner],
        firstFailure: nil
      )

      // then
      #expect(outcome == .success("привет мир"))
    }

    @available(macOS 26.0, *)
    @Test func aLaneFailureOutranksLowConfidenceWhenNoCandidateWins() {
      // given — a lane that never ran may be the one that would have matched; saying
      // "couldn't make out the language" would hide the real, actionable fault
      let garbage = ScoredTranscript(text: ", , ,", confidence: 0.02)

      // when
      let outcome = AppleSpeechTranscriber.settle(
        candidates: [garbage],
        firstFailure: .assetsUnavailable("reservation slots exhausted")
      )

      // then
      #expect(outcome == .failure(.assetsUnavailable("reservation slots exhausted")))
    }

    @available(macOS 26.0, *)
    @Test func allLanesGarbageWithoutFailuresIsLowConfidence() {
      // given
      let candidates = [
        ScoredTranscript(text: ", , ,", confidence: 0.02),
        ScoredTranscript(text: "Hello des Voice месседж", confidence: 0.21),
      ]

      // when
      let outcome = AppleSpeechTranscriber.settle(candidates: candidates, firstFailure: nil)

      // then
      #expect(outcome == .failure(.lowConfidence))
    }

    @available(macOS 26.0, *)
    @Test func everyLaneFailingSettlesAsTheFirstFailure() {
      // given / when
      let outcome = AppleSpeechTranscriber.settle(
        candidates: [],
        firstFailure: .assetsUnavailable("download failed")
      )

      // then
      #expect(outcome == .failure(.assetsUnavailable("download failed")))
    }

    @available(macOS 26.0, *)
    @Test func aWinnerStillBeatsAFailureFromAnotherLane() {
      // given — one broken locale must not take down a language that worked
      let winner = ScoredTranscript(text: "quick brown fox", confidence: 0.96)

      // when
      let outcome = AppleSpeechTranscriber.settle(
        candidates: [winner],
        firstFailure: .assetsUnavailable("ru-RU download failed")
      )

      // then
      #expect(outcome == .success("quick brown fox"))
    }
  }
#endif
