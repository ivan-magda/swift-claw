import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension FeedbackStoreTests {
  @Test func newerSameSubjectPromptSupersedesAndEnqueuesIndependently() throws {
    // given — two independently authenticated correction targets for the same exact run
    let env = try FeedbackStoreEnvironment.make()
    let firstTarget = env.target(nonce: "prompt-one", signal: .resultCorrection, subject: "41")
    let secondTarget = env.target(nonce: "prompt-two", signal: .resultCorrection, subject: "41")
    let reviewNotice = env.chunk(subject: "41", ordinal: 0, markup: nil)
    try env.createTargets([firstTarget, secondTarget], chunks: [reviewNotice])

    // when
    let first = try env.openChallenge(firstTarget)
    let second = try env.openChallenge(secondTarget, updateId: 2)

    // then — subject-only outbox identity would drop the second prompt
    guard case .challengeOpened(let firstChallenge) = first,
      case .challengeOpened(let secondChallenge) = second
    else {
      Issue.record("expected both correction prompts to open")
      return
    }
    #expect(try env.learning.liveChallenge(ownerUserId: 42, chatId: 42)?.id == secondChallenge.id)
    #expect(try env.challenge(firstChallenge.id)?.supersededBy == secondChallenge.id)
    #expect(try env.challenge(firstChallenge.id)?.consumedAt == nil)
    #expect(
      try env.learning.consumeChallenge(
        id: firstChallenge.id,
        payload: "must not attach",
        now: env.now
      ) == .alreadyConsumed
    )
    #expect(try env.deliveryRows().count == 3)
    #expect(Set(try env.deliveryRows().map(\.deliveryKey)).count == 3)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
    let exposed =
      try env.deliveryRows().map { row in
        [row.deliveryKey, row.payload, row.replyMarkup ?? ""].joined()
      }.joined() + env.feedbackAudits().map(\.args).joined()
    #expect(exposed.contains(firstTarget.nonce) == false)
    #expect(exposed.contains(secondTarget.nonce) == false)
  }

  @Test func challengeReplyStoresExactUTF8AndSupersedesTheExactSubject() throws {
    // given — a prior signal on the same run and an interleaved signal on another run
    let env = try FeedbackStoreEnvironment.make()
    let prior = env.target(nonce: "prior", signal: .resultNotUseful, subject: "41")
    let other = env.target(nonce: "other-run", signal: .resultUseful, subject: "42")
    let correction = env.target(nonce: "correction", signal: .resultCorrection, subject: "41")
    try env.createTargets([prior, other, correction], chunks: [])
    _ = try env.consume(env.tap(target: prior, signal: .resultNotUseful))
    _ = try env.consume(env.tap(target: other, signal: .resultUseful, updateId: 2))
    let opened = try env.openChallenge(correction, updateId: 3)
    guard case .challengeOpened(let challenge) = opened else {
      Issue.record("expected the correction prompt to open")
      return
    }
    let payload = "Café 🚨"

    // when
    let outcome = try env.learning.consumeChallenge(
      id: challenge.id,
      payload: payload,
      now: env.now
    )

    // then — grapheme count, transport id propagation, or job-only supersession all fail here
    guard case .recorded(let event) = outcome else {
      Issue.record("expected the correction event to record")
      return
    }
    let exact = try env.feedbackEvents(
      jobId: env.jobId,
      epoch: env.state.epoch,
      subjectKind: .run,
      subjectDigest: "41"
    )
    #expect(event.payload == payload)
    #expect(event.transportUpdateId == nil)
    #expect(event.signal == .resultCorrection)
    #expect(event.supersedes == exact.first?.id)
    #expect(
      try env.feedbackEvents(
        jobId: env.jobId,
        epoch: env.state.epoch,
        subjectKind: .run,
        subjectDigest: "42"
      ).first?.supersedes == nil
    )
    let audit = try #require(try env.feedbackAudits().last)
    #expect(audit.resultSize == payload.utf8.count)
    #expect(audit.args == "subject_kind=run,subject_digest=41")
    #expect([audit.args, audit.tool, audit.decision].joined().contains(payload) == false)
    #expect(try env.deliveryRows().allSatisfy { $0.payload.contains(payload) == false })
  }

  @Test func challengeSubjectKindsMapToOnlyTheirLegalSignals() throws {
    // given — v11 has no signal column; subject kind is the closed discriminator
    let cases: [(FeedbackSubjectKind, OwnerSignal)] = [
      (.run, .resultCorrection), (.candidate, .candidateEdit),
    ]

    for (offset, entry) in cases.enumerated() {
      let env = try FeedbackStoreEnvironment.make()
      let target = env.target(
        nonce: "kind-\(offset)",
        signal: entry.1,
        subject: "subject-\(offset)",
        kind: entry.0
      )
      try env.createTargets([target], chunks: [])
      guard case .challengeOpened(let challenge) = try env.openChallenge(target) else {
        Issue.record("expected a payload challenge")
        continue
      }
      #expect(try env.eventCount() == 0)
      #expect(try env.feedbackRevision() == 0)

      // when
      let outcome = try env.learning.consumeChallenge(
        id: challenge.id,
        payload: "edit",
        now: env.now
      )

      // then — guessing one signal for both subject kinds makes one case fail
      guard case .recorded(let event) = outcome else {
        Issue.record("expected a payload event")
        continue
      }
      #expect(event.signal == entry.1)
    }
  }

  @Test func mismatchedChallengeTargetAndActionFailClosed() throws {
    // given — a corrupted target says candidate while allowing the run-only correction action
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "mismatched-pair", signal: .resultCorrection, subject: "41")
    try env.createTargets([target], chunks: [])
    try env.setTargetSubjectKind(nonce: target.nonce, kind: .candidate)

    // when
    let outcome = try env.learning.consumeAndOpenChallenge(
      env.tap(target: target, signal: .resultCorrection),
      prompt: env.challengePrompt(target),
      now: env.now
    )

    // then — opensFeedbackChallenge alone would consume the target and create an ambiguous row
    #expect(outcome == .actionMismatch)
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    #expect(try env.rowCount(table: "feedback_challenges") == 0)
  }

  @Test func unsupportedDurableChallengeKindFailsClosedOnRead() throws {
    // given — v11 can physically hold a kind with no payload signal mapping
    let env = try FeedbackStoreEnvironment.make()
    try env.insertChallengeDirectly(kind: .evaluation)

    // when / then — guessing a signal for the row would return it as actionable
    #expect(throws: StoreError.self) {
      _ = try env.learning.liveChallenge(ownerUserId: 42, chatId: 42)
    }
    #expect(try env.eventCount() == 0)
  }

  @Test func challengeCASRejectsReplayExpiryAndStaleEpoch() throws {
    // given — each case reaches an independent predicate on a fresh live challenge
    for failure in ChallengeFailure.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let expiry = failure == .expired ? env.now.addingTimeInterval(1) : nil
      let target = env.target(
        nonce: "failure-\(failure)",
        signal: .resultCorrection,
        subject: "41",
        expiresAt: expiry
      )
      try env.createTargets([target], chunks: [])
      guard case .challengeOpened(let challenge) = try env.openChallenge(target) else {
        Issue.record("expected the challenge to open")
        continue
      }
      if failure == .staleEpoch {
        try env.setEpoch(2)
      }
      if failure == .replay {
        _ = try env.learning.consumeChallenge(id: challenge.id, payload: "first", now: env.now)
      }

      // when
      let outcome = try env.learning.consumeChallenge(
        id: challenge.id,
        payload: "second",
        now: failure == .expired ? target.expiresAt : env.now
      )

      // then — deleting this case's CAS predicate would append another event and revision
      #expect(outcome == failure.outcome)
      #expect(try env.eventCount() == (failure == .replay ? 1 : 0))
      #expect(try env.feedbackRevision() == (failure == .replay ? 1 : 0))
    }
  }

  @Test func promptCollisionRollsBackTargetConsumptionAndChallenge() throws {
    // given — the second prompt identity exists, so the first insert precedes the collision
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "prompt-collision", signal: .resultCorrection, subject: "41")
    try env.createTargets([target], chunks: [])
    let first = try #require(env.challengePrompt(target).first)
    let secondPayload = "Second prompt chunk."
    let second = LearningNoticeChunk(
      subjectDigest: first.subjectDigest,
      ordinal: 1,
      chatId: first.chatId,
      payload: secondPayload,
      payloadHash: ContentHash.fnv1a(secondPayload)
    )
    let prompt = [first, second]
    try env.createTargets([], chunks: [second])

    // when / then — accepting INSERT OR IGNORE would consume a target with no new prompt
    #expect(throws: StoreError.self) {
      _ = try env.learning.consumeAndOpenChallenge(
        env.tap(target: target, signal: .resultCorrection),
        prompt: prompt,
        now: env.now
      )
    }
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    #expect(try env.rowCount(table: "feedback_challenges") == 0)
    #expect(try env.deliveryRows().count == 1)
    #expect(try env.deliveryRows().first?.payload == secondPayload)
  }

  @Test func challengeAuditFailureRollsBackPayloadEventAndRevision() throws {
    // given — a live challenge and a database failure at the transaction's final audit row
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "audit-payload", signal: .resultCorrection, subject: "41")
    try env.createTargets([target], chunks: [])
    guard case .challengeOpened(let challenge) = try env.openChallenge(target) else {
      Issue.record("expected the challenge to open")
      return
    }
    try env.forceFeedbackAuditFailure()

    // when / then — moving audit out of the transaction would leave all prior mutations behind
    #expect(throws: StoreError.self) {
      _ = try env.learning.consumeChallenge(id: challenge.id, payload: "private", now: env.now)
    }
    #expect(try env.learning.liveChallenge(ownerUserId: 42, chatId: 42)?.id == challenge.id)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
  }

  @Test func liveChallengePartialUniqueIndexMapsAndRollsBackDirectSQL() throws {
    // given — one mapped transaction inserts two physically live rows for the same owner DM
    let env = try FeedbackStoreEnvironment.make()

    // when
    let failure: StoreError?
    do {
      try env.insertTwoLiveChallengesDirectly()
      failure = nil
    } catch let error {
      failure = error
    }

    // then — application supersession cannot make this pass; the v11 partial index must fire
    guard case .unexpected = failure else {
      Issue.record("expected the mapped live-challenge unique-index failure")
      return
    }
    #expect(try env.rowCount(table: "feedback_challenges") == 0)
  }
}

private enum ChallengeFailure: CaseIterable {
  case replay
  case expired
  case staleEpoch

  var outcome: FeedbackOutcome {
    switch self {
    case .replay: .alreadyConsumed
    case .expired: .expired
    case .staleEpoch: .staleEpoch
    }
  }
}
