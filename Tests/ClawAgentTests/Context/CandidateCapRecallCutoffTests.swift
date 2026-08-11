import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct CandidateCapRecallCutoffTests {
  @Test func candidateCapDropsZeroScoreHitsAndKeepsBestScoresFirst() {
    // given
    let weak = hit(id: 1, sqliteBM25: -1)
    let zero = hit(id: 2, sqliteBM25: 0)
    let strong = hit(id: 3, sqliteBM25: -10)
    let medium = hit(id: 4, sqliteBM25: -5)

    // when
    let selected = CandidateCapRecallCutoff.select(
      hits: [weak, zero, strong, medium],
      limit: 3
    )

    // then
    #expect(selected.map(\.id) == [3, 4, 1])
  }

  @Test func candidateCapAppliesLimitAfterSortingAndZeroFilter() {
    // given
    let hits = [
      hit(id: 1, sqliteBM25: -1),
      hit(id: 2, sqliteBM25: -2),
      hit(id: 3, sqliteBM25: -3),
    ]

    // when
    let selected = CandidateCapRecallCutoff.select(hits: hits, limit: 2)

    // then
    #expect(selected.map(\.id) == [3, 2])
  }

  @Test func candidateCapReturnsEmptyForNonPositiveLimit() {
    // given
    let hits = [hit(id: 1, sqliteBM25: -1)]

    // when
    let selected = CandidateCapRecallCutoff.select(hits: hits, limit: 0)

    // then
    #expect(selected.isEmpty)
  }

  @Test func candidateCapBreaksScoreTiesByRecencyThenIdentifier() {
    // given
    let older = hit(id: 1, sqliteBM25: -2, createdAt: Date(timeIntervalSince1970: 10))
    let newerHighID = hit(id: 3, sqliteBM25: -2, createdAt: Date(timeIntervalSince1970: 20))
    let newerLowID = hit(id: 2, sqliteBM25: -2, createdAt: Date(timeIntervalSince1970: 20))

    // when
    let selected = CandidateCapRecallCutoff.select(
      hits: [newerHighID, older, newerLowID],
      limit: 3
    )

    // then
    #expect(selected.map(\.id) == [2, 3, 1])
  }
}

private func hit(
  id: Int64,
  sqliteBM25: Double,
  createdAt: Date? = nil
) -> RecallHit {
  RecallHit(
    id: id,
    sessionId: 100 + id,
    role: .user,
    content: "message \(id)",
    score: RecallScore(sqliteBM25: sqliteBM25),
    createdAt: createdAt ?? Date(timeIntervalSince1970: Double(id))
  )
}
