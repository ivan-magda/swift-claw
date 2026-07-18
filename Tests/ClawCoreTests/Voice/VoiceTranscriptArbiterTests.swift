import Foundation
import Testing

@testable import ClawCore

@Suite struct VoiceTranscriptArbiterTests {
  @Test func picksTheHighestConfidenceCandidateAboveTheFloor() {
    // given — the measured mismatch shape: garbage scores ~0.02, the right language ~0.84
    let english = ScoredTranscript(text: ", , ,", confidence: 0.02)
    let russian = ScoredTranscript(text: "Привет, это голосовое сообщение", confidence: 0.84)

    // when
    let winner = VoiceTranscriptArbiter.winner(among: [english, russian])

    // then
    #expect(winner == russian)
  }

  @Test func rejectsWhenEveryScoredCandidateIsBelowTheFloor() {
    // given — wrong-language output can look like plausible text, so low scores must lose
    let candidates = [
      ScoredTranscript(text: ", , ,", confidence: 0.02),
      ScoredTranscript(text: "Hello des Voice месседж", confidence: 0.21),
    ]

    // when
    let winner = VoiceTranscriptArbiter.winner(among: candidates)

    // then
    #expect(winner == nil)
  }

  @Test func fallsBackToTheFirstCandidateWhenNoConfidenceExists() {
    // given — an engine that emits no confidence data must not brick the feature
    let first = ScoredTranscript(text: "first lane", confidence: nil)
    let second = ScoredTranscript(text: "second lane", confidence: nil)

    // when
    let winner = VoiceTranscriptArbiter.winner(among: [first, second])

    // then
    #expect(winner == first)
  }

  @Test func unscoredCandidatesLoseToScoredOnes() {
    // given
    let unscored = ScoredTranscript(text: "no data", confidence: nil)
    let scored = ScoredTranscript(text: "confident", confidence: 0.9)

    // when
    let winner = VoiceTranscriptArbiter.winner(among: [unscored, scored])

    // then
    #expect(winner == scored)
  }

  @Test func unscoredCandidatesCannotRescueAScoredFieldBelowTheFloor() {
    // given — once any lane produced a measurable score, an unmeasurable lane must not win
    let unscored = ScoredTranscript(text: "no data", confidence: nil)
    let garbage = ScoredTranscript(text: ", , ,", confidence: 0.02)

    // when
    let winner = VoiceTranscriptArbiter.winner(among: [unscored, garbage])

    // then
    #expect(winner == nil)
  }

  @Test func emptyCandidateListHasNoWinner() {
    // given / when
    let winner = VoiceTranscriptArbiter.winner(among: [])

    // then
    #expect(winner == nil)
  }

  @Test func prefersTheEarlierCandidateOnEqualConfidence() {
    // given — candidate order is the configured locale priority
    let preferred = ScoredTranscript(text: "preferred locale", confidence: 0.8)
    let secondary = ScoredTranscript(text: "secondary locale", confidence: 0.8)

    // when
    let winner = VoiceTranscriptArbiter.winner(among: [preferred, secondary])

    // then
    #expect(winner == preferred)
  }

  @Test func averageConfidenceIsTheMeanOfTheRunValues() {
    // given / when
    let average = VoiceTranscriptArbiter.averageConfidence([0.5, 1.0])

    // then
    #expect(average == 0.75)
  }

  @Test func averageConfidenceIsNilWithoutRunValues() {
    // given / when
    let average = VoiceTranscriptArbiter.averageConfidence([])

    // then
    #expect(average == nil)
  }

  @Test func thresholdsMatchTheMeasuredSeparation() {
    // given / then — measured lanes: right language ≥ 0.84 average, wrong language ≤ 0.21;
    // the floor must sit between them and the early-accept must only fire on a clear match
    #expect(VoiceTranscriptArbiter.floorConfidence > 0.21)
    #expect(VoiceTranscriptArbiter.floorConfidence < 0.84)
    #expect(VoiceTranscriptArbiter.acceptConfidence > VoiceTranscriptArbiter.floorConfidence)
    #expect(VoiceTranscriptArbiter.acceptConfidence < 0.84)
  }
}
