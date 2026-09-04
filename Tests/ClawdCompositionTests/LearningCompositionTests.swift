import ClawCore
import ClawData
import ClawGateway
import ClawTestSupport
import ClawWorkspace
import Foundation
import Testing

@testable import clawd

/// The composition root is the only production writer of three of the five frozen compatibility
/// fields, and the only place the learning flag decides whether the loop exists at all. The
/// `TurnRunner` hop is tested against a double, so without this suite the real closure never runs.
@Suite struct LearningCompositionTests {
  @Test func theArmedRootFreezesTheSurfaceABoundRunRanOn() throws {
    // given — a real builder over real stores, learning armed, and one bound run from its own fire
    let builder = try LearningComposition.makeBuilder(learningEnabled: true)
    let runId = try LearningComposition.fireBoundRun(builder)
    let freeze = builder.makeLearningSurfaceFreeze(
      toolDefinitions: LearningComposition.toolDefinitions,
      workspace: LearningComposition.workspace()
    )

    // when
    freeze(runId, "pv-at-pickup")

    // then — all five fields, from the values in force at pickup
    let frozen = try #require(try builder.stores.learning.compatibility(runId: runId))
    #expect(frozen.policyVersion == "pv-at-pickup")
    #expect(frozen.contextSchemaVersion == RunSurface.currentContextSchemaVersion)
    #expect(
      frozen.toolCatalogDigest
        == DaemonBuilder.toolCatalogDigest(LearningComposition.toolDefinitions)
    )
    #expect(frozen.skillSetDigest == DaemonBuilder.skillSetDigest([]))
    #expect(frozen.configuredRoute == CompositionAcceptance.qualifiedModel)
    #expect(builder.makeLearningService() != nil)
    #expect(builder.makePinnedLessonStore() != nil)
  }

  @Test func theDisarmedRootComposesNoServiceAndFreezesNothing() throws {
    // given — the same root with `CLAW_LEARNING_ENABLED` unset
    let builder = try LearningComposition.makeBuilder(learningEnabled: false)
    let runId = try LearningComposition.fireBoundRun(builder)
    let freeze = builder.makeLearningSurfaceFreeze(
      toolDefinitions: LearningComposition.toolDefinitions,
      workspace: LearningComposition.workspace()
    )

    // when
    freeze(runId, "pv-at-pickup")

    // then — the daemon behaves exactly as it does today: nothing to sweep, nothing frozen
    #expect(builder.makeLearningService() == nil)
    #expect(try builder.stores.learning.compatibility(runId: runId) == nil)
    // The turn path must refuse the pinned read too: a binding written before the flag came off
    // outlives the flag, and an approval parked on it can resume under a disarmed daemon.
    #expect(builder.makePinnedLessonStore() == nil)
  }

  @Test func theDisarmedRootStillComposesTheRedactedLearningReader() async throws {
    // given — retained learning state exists although the optional worker service is disabled.
    let response = HTTPResult(
      statusCode: 200,
      headers: [:],
      body: Data(#"{"ok":true,"result":{"message_id":7,"chat":{"id":777}}}"#.utf8)
    )
    let http = ScriptedHTTPExecutor([.ok(response)])
    let builder = try LearningComposition.makeBuilder(learningEnabled: false, http: http)
    try builder.stores.allowlist.seedAllowlist(userIds: [777])
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let job = try LearningComposition.createJob(builder, now: now, label: "tg-token")
    _ = try builder.stores.learning.armJob(jobId: job.id, now: now)
    let router = builder.makeIntakeRouter(
      coordination: DaemonBuilder.TurnCoordination(),
      turnRunner: IdleCompositionTurns(),
      imageCache: ImageCache(),
      scheduleSurface: LearningComposition.scheduleSurface(builder),
      approvalCallbacks: nil,
      doctor: IdleCompositionDoctor(),
      learning: nil
    )

    // when
    let outcome = await router.handle(
      rawUpdate: RawUpdate(
        updateId: 70,
        message: RawMessage(
          messageId: 70,
          fromUserId: 777,
          chatId: 777,
          text: "/learning \(job.id)",
          caption: nil,
          mediaKind: nil,
          chatKind: .private,
          chatTitle: nil,
          messageThreadId: nil,
          senderDisplayName: nil
        ),
        editedMessage: nil
      )
    )

    // then — omitting the independent store/redactor injection hides state or leaks root secrets.
    #expect(outcome == .processed)
    #expect(builder.makeLearningService() == nil)
    let call = try #require(await http.recorded.first)
    let body = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    let text = try #require(body["text"] as? String)
    #expect(text.contains("Schedule \(job.id)"))
    #expect(text.contains(SecretRedactor.replacement))
    #expect(text.contains("tg-token") == false)
  }

  @Test func feedbackRouterIsComposedOnlyWhileLearningIsArmed() async throws {
    // given — each real root owns a live target, but only one has the learning feature armed
    for learningEnabled in [true, false] {
      let builder = try LearningComposition.makeBuilder(learningEnabled: learningEnabled)
      try builder.stores.allowlist.seedAllowlist(userIds: [777])
      let now = Date(timeIntervalSince1970: 1_782_000_600)
      let job = try LearningComposition.createJob(builder, now: now)
      let state = try builder.stores.learning.armJob(jobId: job.id, now: now)
      let target = NewFeedbackTarget(
        nonce: "composition-\(learningEnabled)",
        jobId: job.id,
        epoch: state.epoch,
        subjectKind: .run,
        subjectDigest: "41",
        allowedActions: [.resultUseful],
        ownerUserId: 777,
        chatId: 777,
        expiresAt: .distantFuture
      )
      try builder.stores.learning.createTargets([target], chunks: [], now: now)
      let router = builder.makeIntakeRouter(
        coordination: DaemonBuilder.TurnCoordination(),
        turnRunner: IdleCompositionTurns(),
        imageCache: ImageCache(),
        scheduleSurface: LearningComposition.scheduleSurface(builder),
        approvalCallbacks: nil,
        doctor: IdleCompositionDoctor(),
        learning: nil
      )
      let update = RawUpdate(
        updateId: learningEnabled ? 80 : 81,
        message: nil,
        editedMessage: nil,
        callback: RawCallback(
          callbackId: "composition-feedback",
          fromUserId: 777,
          chatId: 777,
          messageId: 1,
          data: FeedbackKeyboard.callbackData(
            nonce: target.nonce,
            action: .resultUseful
          )
        )
      )

      // when
      let outcome = await router.handle(rawUpdate: update)

      // then — wiring feedback regardless of the flag consumes the disarmed root's live target
      let stored = try #require(try builder.stores.learning.feedbackTarget(nonce: target.nonce))
      #expect(outcome == (learningEnabled ? .processed : .skipped))
      #expect((stored.consumedAt != nil) == learningEnabled)
    }
  }

  @Test func freeTextChallengeOpeningAndInterceptionShareTheLearningFeatureGate() async throws {
    // given — both roots hold the same kind of payload-bearing target
    for learningEnabled in [true, false] {
      let builder = try LearningComposition.makeBuilder(learningEnabled: learningEnabled)
      try builder.stores.allowlist.seedAllowlist(userIds: [777])
      let now = Date(timeIntervalSince1970: 1_782_000_600)
      let job = try LearningComposition.createJob(builder, now: now)
      let state = try builder.stores.learning.armJob(jobId: job.id, now: now)
      let target = NewFeedbackTarget(
        nonce: "composition-challenge-\(learningEnabled)",
        jobId: job.id,
        epoch: state.epoch,
        subjectKind: .run,
        subjectDigest: "41",
        allowedActions: [.resultCorrection],
        ownerUserId: 777,
        chatId: 777,
        expiresAt: .distantFuture
      )
      try builder.stores.learning.createTargets([target], chunks: [], now: now)
      if !learningEnabled {
        let residual = NewFeedbackTarget(
          nonce: "residual-disabled-challenge",
          jobId: job.id,
          epoch: state.epoch,
          subjectKind: .run,
          subjectDigest: "43",
          allowedActions: [.resultCorrection],
          ownerUserId: 777,
          chatId: 777,
          expiresAt: .distantFuture
        )
        try builder.stores.learning.createTargets([residual], chunks: [], now: now)
        let tap = FeedbackTap(
          nonce: residual.nonce,
          signal: .resultCorrection,
          ownerUserId: 777,
          chatId: 777,
          transportUpdateId: 89
        )
        let opened = try builder.stores.learning.consumeAndOpenChallenge(
          tap,
          prompt: LearningComposition.challengePrompt(for: tap),
          now: now
        )
        guard case .challengeOpened = opened else {
          Issue.record("failed to seed the residual challenge")
          return
        }
      }
      let coordination = DaemonBuilder.TurnCoordination()
      let router = builder.makeIntakeRouter(
        coordination: coordination,
        turnRunner: IdleCompositionTurns(),
        imageCache: ImageCache(),
        scheduleSurface: LearningComposition.scheduleSurface(builder),
        approvalCallbacks: nil,
        doctor: IdleCompositionDoctor(),
        learning: nil
      )

      // when — correction tap, then its free-text payload
      let callbackOutcome = await router.handle(
        rawUpdate: RawUpdate(
          updateId: learningEnabled ? 90 : 91,
          message: nil,
          editedMessage: nil,
          callback: RawCallback(
            callbackId: "composition-challenge",
            fromUserId: 777,
            chatId: 777,
            messageId: 1,
            data: FeedbackKeyboard.callbackData(
              nonce: target.nonce,
              action: .resultCorrection
            )
          )
        )
      )
      let opened = try builder.stores.learning.liveChallenge(ownerUserId: 777, chatId: 777)
      #expect(opened?.subjectDigest == (learningEnabled ? "41" : "43"))
      let ownerText = "The result omitted the price change."
      let messageOutcome = await router.handle(
        rawUpdate: RawUpdate(
          updateId: learningEnabled ? 92 : 93,
          message: RawMessage(
            messageId: 2,
            fromUserId: 777,
            chatId: 777,
            text: ownerText,
            caption: nil,
            mediaKind: nil,
            chatKind: .private,
            chatTitle: nil,
            messageThreadId: nil,
            senderDisplayName: nil
          ),
          editedMessage: nil
        )
      )
      let remaining = try builder.stores.learning.liveChallenge(ownerUserId: 777, chatId: 777)
      let sessionId = try builder.stores.sessionMessages.findSession(
        sessionKey: SessionKey.telegramDM(chatId: 777)
      )
      var ordinaryHistory: [StoredMessage] = []
      if let sessionId {
        ordinaryHistory = try builder.stores.sessionMessages.loadContextSnapshot(
          sessionId: sessionId,
          throughMessageId: .max,
          limit: 10
        ).history
      }
      let runHealth = try builder.stores.runs.runsHealth(now: now)

      // then — disabling learning wires neither half and leaves the target untouched
      let stored = try #require(try builder.stores.learning.feedbackTarget(nonce: target.nonce))
      #expect(callbackOutcome == (learningEnabled ? .processed : .skipped))
      #expect((stored.consumedAt != nil) == learningEnabled)
      #expect(messageOutcome == .processed)
      #expect((remaining == nil) == learningEnabled)
      #expect(ordinaryHistory.map(\.content) == (learningEnabled ? [] : [ownerText]))
      #expect(runHealth.inFlight == (learningEnabled ? 0 : 1))
    }
  }

  @Test func theToolCatalogDigestCoversRiskAndIgnoresCatalogOrder() {
    // given — the same two tools at different risk tiers, and the same pair reordered
    let safe = LearningComposition.tool(name: "file_read", risk: .safe)
    let ask = LearningComposition.tool(name: "file_write", risk: .ask)
    let downgraded = LearningComposition.tool(name: "file_write", risk: .safe)

    // when
    let digest = DaemonBuilder.toolCatalogDigest([safe, ask])

    // then — a risk downgrade is a different surface; declaration order is not
    #expect(DaemonBuilder.toolCatalogDigest([ask, safe]) == digest)
    #expect(DaemonBuilder.toolCatalogDigest([safe, downgraded]) != digest)
    #expect(DaemonBuilder.toolCatalogDigest([safe]) != digest)
  }

  @Test func theSkillSetDigestCoversDescriptionsAndIgnoresScanOrder() {
    // given — the index rows the context injects, which is name plus description
    let plan = LearningComposition.skill(name: "plan", description: "Draft a plan")
    let ship = LearningComposition.skill(name: "ship", description: "Cut a release")
    let reworded = LearningComposition.skill(name: "ship", description: "Publish a release")

    // when
    let digest = DaemonBuilder.skillSetDigest([plan, ship])

    // then
    #expect(DaemonBuilder.skillSetDigest([ship, plan]) == digest)
    #expect(DaemonBuilder.skillSetDigest([plan, reworded]) != digest)
    #expect(DaemonBuilder.skillSetDigest([]) != digest)
  }
}

// MARK: - Fixtures

private enum LearningComposition {
  static let toolDefinitions = [
    tool(name: "file_read", risk: .safe),
    tool(name: "web_fetch", risk: .ask),
  ]

  static func makeBuilder(
    learningEnabled: Bool,
    http: ScriptedHTTPExecutor = ScriptedHTTPExecutor([])
  ) throws -> DaemonBuilder {
    var environment = [
      AppConfig.EnvKey.stateRoot: NSTemporaryDirectory() + "clawd-learn-" + UUID().uuidString,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
    ]
    if learningEnabled {
      environment[AppConfig.EnvKey.learningEnabled] = "true"
    }
    return try CompositionAcceptance.makeBuilder(
      http: http,
      config: try AppConfig.load(environment: environment)
    )
  }

  /// A scheduled job fired through the production path, so the run carries the real binding the
  /// freeze joins against — and carries none at all when the flag is off.
  static func fireBoundRun(_ builder: DaemonBuilder) throws -> Int64 {
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let job = try createJob(builder, now: now)
    guard case .fired(let fired) = try builder.stores.scheduledJobs.fireNow(jobId: job.id, now: now)
    else {
      throw StoreError.unexpected("job \(job.id) refused to fire")
    }
    return fired.runId
  }

  static func createJob(
    _ builder: DaemonBuilder,
    now: Date,
    label: String = "digest"
  ) throws -> ScheduledJob {
    try builder.stores.scheduledJobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: label,
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
  }

  static func scheduleSurface(_ builder: DaemonBuilder) -> ScheduleSurface {
    ScheduleSurface(
      parser: IdleCompositionScheduleParser(),
      validator: ScheduleDraftValidator(minIntervalMinutes: 5, defaultTimezone: .gmt),
      calculator: OccurrenceCalculator(),
      jobs: builder.stores.scheduledJobs,
      commands: builder.stores.scheduleCommands
    )
  }

  static func workspace() -> FileSystemWorkspace {
    FileSystemWorkspace(root: URL(fileURLWithPath: NSTemporaryDirectory() + UUID().uuidString))
  }

  static func tool(name: String, risk: RiskLevel) -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: name,
      parameters: .object([:]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: risk
    )
  }

  static func skill(name: String, description: String) -> SkillDescriptor {
    SkillDescriptor(
      name: name,
      description: description,
      directory: URL(fileURLWithPath: "/tmp/skills/" + name)
    )
  }

  static func challengePrompt(for tap: FeedbackTap) -> [LearningNoticeChunk] {
    let payload = "Reply with what this result should have done differently."
    return [
      LearningNoticeChunk(
        subjectDigest: FeedbackChallengeDeliveryIdentity.digest(targetNonce: tap.nonce),
        ordinal: 0,
        chatId: tap.chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload)
      )
    ]
  }
}

private actor IdleCompositionTurns: TurnDispatching {
  func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws {}
}

private struct IdleCompositionScheduleParser: ScheduleDraftParsing {
  func parse(ownerText: String, sessionId: Int64) async -> ScheduleDraftParseResult {
    .unparseable
  }
}

private struct IdleCompositionDoctor: DoctorReporting {
  func report() async -> DoctorReport {
    DoctorReport()
  }

  func scanSkills() async -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}
