import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite
struct TurnProgressBudgetNoticeTests {
  enum Notice: CaseIterable {
    case daily, proactive
  }

  @Test(arguments: Notice.allCases, [false, true])
  func budgetNoticeDrainsAndRestoresTheOwnersDraft(notice: Notice, sendFails: Bool) async throws {
    // given — a distinct owner DM remains active while a group or scheduled run commits.
    let probes = PresentationProbes()
    let drafts = ClosingDrafts(blockingCall: 2)
    defer { drafts.releaseCleanup.open() }
    let transport = RecordingTransport(
      sendError: sendFails ? .transport("budget notice unavailable") : nil
    )
    let env = try makeEnv(
      agentOutcome: .respond(okResponse()),
      breaker: BudgetBreaker(budget: .default),
      transport: transport,
      ownerChatID: 42,
      presentationsFactory: { outbox in
        try makePresentations(
          clock: probes.clock,
          drafts: drafts,
          typing: RecordingTyping(),
          progressEnabled: false,
          outbox: outbox
        )
      }
    )
    let registry = try #require(env.runner.presentations)
    _ = try #require(try env.runner.runs.pickUp(runID: env.runID, now: Date()))
    let reporter = await registry.begin(
      scope: TurnScope(
        runID: env.runID,
        sessionID: env.sessionID,
        chatID: env.chatID,
        threadID: nil,
        mode: .direct,
        origin: .interactive,
        requesterUserID: env.chatID
      )
    )
    #expect(await probes.ready())
    await reporter?.publish(.answerPreview("unchanged owner answer"))
    #expect(await probes.advance(1))
    let secondDraft = Task { await probes.advance(1) }
    #expect(await drafts.started.waitUntilOpen())
    let target = try Self.seedNoticeRun(env: env, notice: notice)

    // when
    let commit = Task {
      try await env.runner.commit(
        target.outcome,
        runID: target.runID,
        sessionID: target.sessionID,
        chatID: target.chatID,
        mode: notice == .daily ? .group : .direct,
        ownerNotices: [],
        origin: notice == .daily ? .interactive : .scheduled
      )
    }
    let draining = await drafts.cancelled.waitUntilOpen()
    let prematureAttempts = await transport.sendAttempts
    drafts.releaseCleanup.open()
    try await commit.value
    #expect(await secondDraft.value)
    // Scheduled final rows share the DM target and must be recorded before its draft resumes.
    await OutboxDispatcher(
      outbox: env.outbox,
      delivery: RecordingTransport(),
      signal: OutboxSignal(),
      presentations: registry,
      logger: TestLog.silent
    ).drainOnce()
    #expect(await probes.advance(5))
    await registry.shutdown()

    // then — five normal probes restore the same frame, well before the 25-second refresh.
    #expect(draining)
    #expect(prematureAttempts == 0)
    #expect(await transport.sendAttempts == 1)
    let expected = notice == .daily ? Degradation.dailyCapTripped : Degradation.proactiveCapTripped
    #expect(await transport.sent.contains { $0.text == expected } == !sendFails)
    #expect(await drafts.markdowns == Array(repeating: "unchanged owner answer", count: 3))
  }
}

// MARK: - Distinct Terminal Runs

private extension TurnProgressBudgetNoticeTests {
  struct NoticeRun {
    let runID: Int64
    let sessionID: Int64
    let chatID: Int64
    let outcome: TurnOutcome
  }

  static func seedNoticeRun(env: Env, notice: Notice) throws -> NoticeRun {
    let runID: Int64
    let sessionID: Int64
    let chatID: Int64
    let outcome: TurnOutcome
    if notice == .daily {
      chatID = -7
      let claim = try env.sessionMessages.claimAndPersistInbound(
        InboundMessage(
          updateID: 2,
          sessionKey: SessionKey.telegramTopic(chatID: chatID, threadID: nil),
          chatID: chatID,
          userID: env.chatID,
          text: "group work",
          isEdited: false,
          journalAdmission: nil,
          ts: Date()
        )
      )
      runID = try #require(claim.runID)
      sessionID = try #require(claim.sessionID)
      let usage = ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "budget-notice-trip"),
        runID: runID,
        sessionID: sessionID,
        model: "m",
        promptTokens: RunBudget.default.dayTokenCeiling,
        completionTokens: 0,
        costUSD: 0,
        costSource: .heuristic,
        isEstimated: true,
        ts: Date()
      )
      outcome = TurnOutcome(
        result: .completed(content: "group answer", usage: usage, providerState: nil)
      )
    } else {
      chatID = env.chatID
      let jobs = ScheduledJobStoreGRDB(writer: env.queue)
      let job = try jobs.create(
        NewScheduledJob(
          ownerChatID: chatID,
          label: "digest",
          prompt: "updates",
          recurrence: nil,
          timezone: "UTC",
          nextOccurrence: Date()
        ),
        now: Date()
      )
      guard case .fired(let fired) = try jobs.fireNow(jobID: job.id, now: Date()) else {
        throw StoreError.unexpected("scheduled fixture did not fire")
      }
      runID = fired.runID
      sessionID = fired.sessionID
      outcome = TurnOutcome(result: .budgetStopped(cap: BudgetGate.proactivePerDayCap))
    }
    _ = try #require(try env.runner.runs.pickUp(runID: runID, now: Date()))
    return NoticeRun(runID: runID, sessionID: sessionID, chatID: chatID, outcome: outcome)
  }
}
