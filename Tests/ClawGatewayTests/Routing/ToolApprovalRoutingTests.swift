import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

@Suite struct ToolApprovalRoutingTests {
  private struct Fixture {
    let router: MessageRouter
    let runner: FakeTurnRunner
    let registry: PendingConfirmationRegistry
    let sessions: SessionMessageStoreGRDB
    let transport: RecordingTransport
  }

  private func makeFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [7])
    let registry = PendingConfirmationRegistry()
    let runner = FakeTurnRunner()
    let transport = RecordingTransport()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: sessions,
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: registry,
      botUsername: nil,
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: runner,
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      logger: TestLog.silent
    )
    return Fixture(
      router: router,
      runner: runner,
      registry: registry,
      sessions: sessions,
      transport: transport
    )
  }

  private let approval = ToolApprovalRequest(
    action: ToolAction(tool: "web_fetch", target: "https://example.com/a?q=1"),
    reason: .exfilTrifecta
  )

  @Test func yesDispatchesTheTurnWithTheGrantAndClears() async throws {
    // given — a parked tool approval (the exfil-trifecta kind)
    let fixture = try makeFixture()
    let sessionId = try fixture.sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 7),
      now: Date()
    )
    await fixture.registry.park(.toolApproval(approval), sessionId: sessionId)

    // when
    let outcome = await fixture.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "yes"))

    // then — an ordinary turn dispatched WITH the one-turn grant; entry cleared
    #expect(outcome == .processed)
    await fixture.runner.waitForCalls(atLeast: 1)
    let call = await fixture.runner.calls[0]
    let expectedGrant = OneTurnGrant(
      action: ToolAction(tool: "web_fetch", target: "https://example.com/a?q=1")
    )
    #expect(call.grant == expectedGrant)
    #expect(await fixture.registry.pending(sessionId: sessionId) == nil)
  }

  @Test func anythingElseDispatchesNormallyAndClears() async throws {
    // given
    let fixture = try makeFixture()
    let sessionId = try fixture.sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 7),
      now: Date()
    )
    await fixture.registry.park(.toolApproval(approval), sessionId: sessionId)

    // when — a "no" is a normal turn, so the model can respond naturally (§14)
    let outcome = await fixture.router.handle(
      rawUpdate: textUpdate(id: 2, from: 7, text: "no, don't do that")
    )

    // then
    #expect(outcome == .processed)
    await fixture.runner.waitForCalls(atLeast: 1)
    #expect(await fixture.runner.calls[0].grant == nil)
    #expect(await fixture.registry.pending(sessionId: sessionId) == nil)
  }

  @Test func plainTurnsCarryNoGrant() async throws {
    // given — nothing parked
    let fixture = try makeFixture()

    // when
    _ = await fixture.router.handle(rawUpdate: textUpdate(id: 3, from: 7, text: "hello"))

    // then
    await fixture.runner.waitForCalls(atLeast: 1)
    #expect(await fixture.runner.calls[0].grant == nil)
  }

  @Test func newClearsThePendingEntry() async throws {
    // given (§18-E)
    let fixture = try makeFixture()
    let sessionId = try fixture.sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 7),
      now: Date()
    )
    await fixture.registry.park(.toolApproval(approval), sessionId: sessionId)

    // when
    _ = await fixture.router.handle(rawUpdate: textUpdate(id: 4, from: 7, text: "/new"))

    // then — deny-by-default: a later "yes" is just a turn
    #expect(await fixture.registry.pending(sessionId: sessionId) == nil)
  }
}
