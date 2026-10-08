import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite
struct JournalCommandRoutingTests {
  @Test
  func disabledInspectionStillRequiresConfiguredOwner() async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer { fixture.removeFiles() }
    let day = JournalDay.containing(fixture.now, timeZone: .gmt)
    let privateText = "Owner journal contents"
    try fixture.files.append(day: day, text: privateText)
    let harness = try makeRouter(fixture: fixture, enabled: false)

    // when
    _ = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 1,
        from: 41,
        text: "/journal show \(day.isoDate)"
      )
    )
    let staleOwnerReply = await harness.transport.sent.last?.text
    _ = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 2,
        from: 42,
        chat: 41,
        text: "/journal show \(day.isoDate)"
      )
    )
    let mismatchedChatReply = await harness.transport.sent.last?.text
    _ = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 3,
        from: 42,
        text: "/journal show \(day.isoDate)"
      )
    )
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 4, from: 42, text: "/journal"))

    // then
    #expect(staleOwnerReply?.contains(privateText) == false)
    #expect(mismatchedChatReply?.contains(privateText) == false)
    let texts = await harness.transport.sent.map(\.text)
    #expect(texts.contains { $0.contains(privateText) })
    #expect(texts.last?.contains("disabled") == true)
    #expect(texts.last?.contains(day.isoDate) == true)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  enum Removal: CaseIterable {
    case missing
    case refused
  }

  @Test(arguments: Removal.allCases)
  func removalOutcomeKeepsSelectedWorkCancelled(_ removal: Removal) async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer { fixture.removeFiles() }
    let sources = try fixture.seed(count: 1, at: fixture.now)
    let day = sources[0].day
    let path = fixture.root.appendingPathComponent("memory/\(day.isoDate).md")
    if removal == .refused {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let harness = try makeRouter(fixture: fixture, enabled: false)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 1,
        from: 42,
        text: "/journal delete \(day.isoDate)"
      )
    )

    // when
    let result = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then
    #expect(result == .processed)
    #expect(try fixture.store.pendingCount(day: day, ownerUserID: 42) == 0)
    #expect(FileManager.default.fileExists(atPath: path.path) == (removal == .refused))
    let reply = try #require(await harness.transport.sent.last?.text)
    #expect(reply.contains(removal == .refused ? "failed" : "No journal file"))
    #expect(await harness.pending.pending(sessionID: fixture.sessionID) == nil)
  }

  @Test
  func longShowMarksShorteningWithinTelegramLimit() async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer { fixture.removeFiles() }
    let day = JournalDay.containing(fixture.now, timeZone: .gmt)
    try fixture.files.append(day: day, text: String(repeating: "Русский текст. ", count: 1000))
    let harness = try makeRouter(fixture: fixture, enabled: false)

    // when
    _ = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 1,
        from: 42,
        text: "/journal show \(day.isoDate)"
      )
    )

    // then
    let text = try #require(await harness.transport.sent.last?.text)
    #expect(text.contains("Shortened"))
    #expect(text.count <= TelegramMessageLimits.maxPlainMessageCharacters)
    #expect(text.contains("Русский текст."))
  }

  @Test
  func confirmedDeleteCancelsOnlyThatDayBeforePublication() async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer { fixture.removeFiles() }
    let sources = try fixture.seed(count: 12, at: fixture.now.addingTimeInterval(-86_400))
    let day = sources[0].day
    let otherSources = try fixture.seed(count: 1, at: fixture.now, firstID: 200)
    let otherDay = otherSources[0].day
    let originalOtherDayText = "Other day edits"
    try fixture.files.append(day: day, text: "Owner edits")
    try fixture.files.append(day: otherDay, text: originalOtherDayText)
    let gate = WorkspaceMutationGate()
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let response = ChatResponse(
      content: """
        {"notes":[{"kind":"decision","attribution":"owner","text":"Use SQLite.",
        "source_ids":["message:1"]}]}
        """,
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 123, completionTokens: 17, totalTokens: 140),
      costFromProvider: 0.01
    )
    let laterResponse = ChatResponse(
      content: response.content.replacingOccurrences(of: "message:1", with: "message:100"),
      finishReason: "stop",
      usage: response.usage,
      costFromProvider: 0.01
    )
    let provider = SequenceProvider(
      [response, laterResponse],
      beforeResponse: {
        entered.open()
        await release.waitIgnoringCancellation()
      }
    )
    let worker = fixture.worker(provider: provider, gate: gate)
    let harness = try makeRouter(fixture: fixture, enabled: true, gate: gate)
    let drain = Task { await worker.sweep(now: fixture.now) }
    defer { drain.cancel() }
    guard await entered.waitUntilOpen() else {
      release.open()
      await drain.value
      Issue.record("Journal inference did not start")
      return
    }
    let pendingForSelectedDay = try fixture.store.pendingCount(day: day, ownerUserID: 42)

    // when
    _ = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 10,
        from: 42,
        text: "/journal delete \(day.isoDate)"
      )
    )
    let confirmationText = try #require(await harness.transport.sent.last?.text)
    let yes = textUpdate(id: 11, from: 42, text: "yes")
    #expect(await harness.router.handle(rawUpdate: yes) == .processed)
    release.open()
    await drain.value

    // then
    #expect(confirmationText.contains(String(pendingForSelectedDay)))
    #expect(fixture.files.load(day: day).outcome == .missing)
    #expect(fixture.files.load(day: otherDay).text == originalOtherDayText)
    #expect(try fixture.store.pendingCount(day: day, ownerUserID: 42) == 0)
    #expect(try fixture.usageCallIDs().count == 1)
    #expect(try fixture.store.pendingCount(day: otherDay, ownerUserID: 42) == otherSources.count)
    #expect(await harness.dispatcher.calls.isEmpty)

    // given — a newer delete intent must survive an old confirmation redelivery.
    _ = try fixture.seed(count: 1, at: sources[0].occurredAt, firstID: 100)
    await worker.sweep(now: fixture.now)
    #expect(fixture.files.load(day: day).text.contains("Use SQLite."))
    _ = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 12,
        from: 42,
        text: "/journal delete \(otherDay.isoDate)"
      )
    )

    // when / then
    #expect(await harness.router.handle(rawUpdate: yes) == .skipped)
    #expect(
      await harness.pending.pending(sessionID: fixture.sessionID) == .journalDelete(day: otherDay)
    )
    #expect(fixture.files.load(day: day).outcome == .present)
    #expect(fixture.files.load(day: otherDay).text == originalOtherDayText)
    #expect(try fixture.store.pendingCount(day: otherDay, ownerUserID: 42) == otherSources.count)
    await worker.shutdown()
  }
}

// MARK: - Routing Fixture

private extension JournalCommandRoutingTests {
  struct Harness {
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let pending: PendingConfirmationRegistry
  }

  func makeRouter(
    fixture: JournalWorkerFixture,
    enabled: Bool,
    gate: WorkspaceMutationGate = WorkspaceMutationGate()
  ) throws -> Harness {
    let queue = fixture.queue
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIDs: [41, 42])
    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let pending = PendingConfirmationRegistry()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: pending,
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: AccessControl(allowlist: allowlist, groupChats: []),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      journal: JournalCommandSurface(
        policy: JournalPolicy(enabled: enabled, ownerUserID: 42, timeZoneID: "UTC"),
        store: fixture.store,
        files: fixture.files,
        mutationGate: gate
      ),
      doctor: StubDoctorReporter(),
      now: { fixture.now },
      logger: TestLog.silent
    )
    return Harness(router: router, transport: transport, dispatcher: dispatcher, pending: pending)
  }
}
