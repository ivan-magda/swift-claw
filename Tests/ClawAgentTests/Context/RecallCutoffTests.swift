import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct RecallCutoffTests {
  @Test func candidateCapDropsZeroScoreHitsAndKeepsBestScoresFirst() {
    // given
    let cutoff = CandidateCapRecallCutoff()
    let weak = hit(id: 1, sqliteBM25: -1)
    let zero = hit(id: 2, sqliteBM25: 0)
    let strong = hit(id: 3, sqliteBM25: -10)
    let medium = hit(id: 4, sqliteBM25: -5)

    // when
    let selected = cutoff.select(hits: [weak, zero, strong, medium], limit: 3)

    // then
    #expect(selected.map(\.id) == [3, 4, 1])
  }

  @Test func candidateCapAppliesLimitAfterSortingAndZeroFilter() {
    // given
    let cutoff = CandidateCapRecallCutoff()
    let hits = [
      hit(id: 1, sqliteBM25: -1),
      hit(id: 2, sqliteBM25: -2),
      hit(id: 3, sqliteBM25: -3),
    ]

    // when
    let selected = cutoff.select(hits: hits, limit: 2)

    // then
    #expect(selected.map(\.id) == [3, 2])
  }

  @Test func candidateCapReturnsEmptyForNonPositiveLimit() {
    // given
    let cutoff = CandidateCapRecallCutoff()

    // when
    let selected = cutoff.select(hits: [hit(id: 1, sqliteBM25: -1)], limit: 0)

    // then
    #expect(selected.isEmpty)
  }
}

private func hit(id: Int64, sqliteBM25: Double) -> RecallHit {
  RecallHit(
    id: id,
    sessionId: 100 + id,
    role: .user,
    content: "message \(id)",
    score: RecallScore(sqliteBM25: sqliteBM25),
    createdAt: Date(timeIntervalSince1970: Double(id))
  )
}
