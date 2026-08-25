import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct RetrieverTests {
  private struct Corpus {
    let retriever: RetrieverGRDB
    let queue: DatabaseQueue
    let sessionOne: Int64
    let sessionTwo: Int64
  }

  private func makeCorpus() throws -> Corpus {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let (sessionOne, sessionTwo) = try queue.write { db -> (Int64, Int64) in
      let one = try insertSession(db, key: "s1")
      let two = try insertSession(db, key: "s2")
      return (one, two)
    }
    return Corpus(
      retriever: RetrieverGRDB(writer: queue),
      queue: queue,
      sessionOne: sessionOne,
      sessionTwo: sessionTwo
    )
  }

  @discardableResult
  private func insertSession(_ db: Database, key: String) throws -> Int64 {
    let when = Date(timeIntervalSince1970: 1)
    try db.execute(
      sql:
        "INSERT INTO sessions(session_key, created_ts, updated_ts, tainted) VALUES (?, ?, ?, 0)",
      arguments: [key, when, when]
    )
    return db.lastInsertedRowID
  }

  @discardableResult
  private func insertMessage(
    _ corpus: Corpus,
    sessionId: Int64,
    content: String,
    provenance: Provenance = .trusted,
    at seconds: TimeInterval
  ) throws -> Int64 {
    try corpus.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, 'user', ?, ?, ?)
          """,
        arguments: [
          sessionId, content, provenance.rawValue, Date(timeIntervalSince1970: seconds),
        ]
      )
      return db.lastInsertedRowID
    }
  }

  @Test func untrustedRowsAreNeverRecalled() throws {
    // given — a voice transcript persisted `.untrusted` alongside an ordinary trusted row
    let corpus = try makeCorpus()
    let trustedId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift concurrency typed by the owner",
      at: 10
    )
    try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift concurrency spoken in a forwarded voice note",
      provenance: .untrusted,
      at: 20
    )

    // when
    let hits = try corpus.retriever.searchRelevantMessages(
      query: "swift concurrency",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )

    // then — resurfacing untrusted content would re-ingest it without re-arming session taint
    #expect(hits.map(\.id) == [trustedId])
  }

  @Test func returnsHitsOrderedByBm25BestFirst() throws {
    // given - the higher term-frequency document is the stronger BM25 match.
    let corpus = try makeCorpus()
    let strongId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift swift swift concurrency",
      at: 10
    )
    let weakId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift appears once among many unrelated padding words here today",
      at: 20
    )

    // when
    let hits = try corpus.retriever.searchRelevantMessages(
      query: "swift",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )

    // then - best first; RecallScore wraps the negated BM25 so the leader has the higher score.
    #expect(hits.map(\.id) == [strongId, weakId])
    #expect(hits[0].score >= hits[1].score)
    #expect(hits[0].content == "swift swift swift concurrency")
  }

  @Test func recallsMatchesAcrossSessions() throws {
    // given
    let corpus = try makeCorpus()
    let otherSessionId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "earlier swift discussion",
      at: 10
    )

    // when - querying from session two still finds session one's message.
    let hits = try corpus.retriever.searchRelevantMessages(
      query: "swift",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )

    // then
    #expect(hits.map(\.id) == [otherSessionId])
    #expect(hits[0].sessionId == corpus.sessionOne)
    #expect(hits[0].role == .user)
  }

  @Test func excludesInWindowMessagesOfTheCurrentSession() throws {
    // given - one in-window message (current session, id >= windowStart) and one older out-of-window.
    let corpus = try makeCorpus()
    let oldId = try insertMessage(
      corpus,
      sessionId: corpus.sessionTwo,
      content: "swift earlier note",
      at: 10
    )
    let inWindowId = try insertMessage(
      corpus,
      sessionId: corpus.sessionTwo,
      content: "swift current note",
      at: 20
    )

    // when
    let hits = try corpus.retriever.searchRelevantMessages(
      query: "swift",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: inWindowId,
      excludedMessageIds: [],
      limit: 10
    )

    // then - the in-window message is excluded; the older one remains recallable.
    #expect(hits.map(\.id) == [oldId])
  }

  @Test func includesOtherSessionMessagesAtOrAboveWindowStart() throws {
    // given - one in-window current-session message sets the windowStart; a second
    // message belongs to a DIFFERENT session and has id >= windowStart.
    let corpus = try makeCorpus()
    let windowAnchorId = try insertMessage(
      corpus,
      sessionId: corpus.sessionTwo,
      content: "swift in-window current session",
      at: 10
    )
    let otherSessionMsgId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift other session note",
      at: 20
    )

    // when - the exclusion clause is `session_id = sessionTwo AND id >= windowAnchorId`.
    let hits = try corpus.retriever.searchRelevantMessages(
      query: "swift",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: windowAnchorId,
      excludedMessageIds: [],
      limit: 10
    )

    // then - the other-session message survives: its id >= windowStart but its
    // session_id != currentSessionId, so the session-scoped guard does not exclude it.
    #expect(hits.map(\.id) == [otherSessionMsgId])
  }

  @Test func honorsExplicitlyExcludedMessageIds() throws {
    // given
    let corpus = try makeCorpus()
    let keepId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift keep this",
      at: 10
    )
    let dropId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift drop this",
      at: 20
    )

    // when
    let hits = try corpus.retriever.searchRelevantMessages(
      query: "swift",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: nil,
      excludedMessageIds: [dropId],
      limit: 10
    )

    // then
    #expect(hits.map(\.id) == [keepId])
  }

  @Test func emptyOrPunctuationQueryReturnsNoHits() throws {
    // given
    let corpus = try makeCorpus()
    _ = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift content",
      at: 10
    )

    // when - FTS5Pattern(matchingAnyTokenIn:) yields nil for tokenless input.
    let blank = try corpus.retriever.searchRelevantMessages(
      query: "   ",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )
    let punctuation = try corpus.retriever.searchRelevantMessages(
      query: "!!! ???",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )

    // then
    #expect(blank.isEmpty)
    #expect(punctuation.isEmpty)
  }

  @Test func restrictingToOneSessionDropsEveryOtherSessionsHit() throws {
    // given — the same term recorded in the searching session and in a foreign one
    let corpus = try makeCorpus()
    let ownId = try insertMessage(
      corpus,
      sessionId: corpus.sessionTwo,
      content: "swift concurrency in our own conversation",
      at: 10
    )
    let foreignId = try insertMessage(
      corpus,
      sessionId: corpus.sessionOne,
      content: "swift concurrency somewhere else entirely",
      at: 20
    )

    // when — the same query, once restricted to the searching session and once not
    let restricted = try corpus.retriever.searchRelevantMessages(
      query: "swift concurrency",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: corpus.sessionTwo,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )
    let unrestricted = try corpus.retriever.searchRelevantMessages(
      query: "swift concurrency",
      currentSessionId: corpus.sessionTwo,
      restrictToSessionId: nil,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )

    // then — the restriction removes the foreign hit and nothing else changes
    #expect(restricted.map(\.id) == [ownId])
    #expect(Set(unrestricted.map(\.id)) == Set([ownId, foreignId]))
  }
}
