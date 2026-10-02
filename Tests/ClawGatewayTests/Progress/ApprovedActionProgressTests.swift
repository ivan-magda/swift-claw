import ClawCore
import ClawTestSupport
import ClawTools
import Foundation
import GRDB
import Testing

@testable import ClawGateway

extension TurnProgressLifecycleTests {
  @Test(arguments: [false, true])
  func atomicMemoryProgressWaitsForTheFusedCommit(failInsert: Bool) async throws {
    // given
    let fixtures = ApprovedActionExecutorTests()
    let env = try fixtures.makeSuspendedFixture()
    if failInsert {
      try await env.queue.write { db in
        try db.execute(
          sql: """
            CREATE TRIGGER fail_memory BEFORE INSERT ON memory_items
            BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
            """
        )
      }
    }
    let executor = fixtures.makeExecutor(
      env,
      tools: [MemoryWriteTool(redactor: SecretRedactor(secretValues: []))]
    )
    let approval = fixtures.approval(
      env,
      tool: "memory_write",
      argsJSON: #"{"kind":"project","text":"the plan shipped"}"#,
      target: "memory_item:project:abc123"
    )
    let success = AsyncGate()
    let progress = ToolProgressReporter(
      identify: { _, _ in },
      publish: { state in
        if state == .succeeded {
          let rows = try? await env.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items") ?? 0
          }
          #expect(rows == 1)
          success.open()
        }
      }
    )

    // when
    let outcome = await executor.executeApproved(approval, progress: progress)

    // then
    #expect(outcome == (failInsert ? .storeFailed : .committed))
    #expect(success.isOpen == !failInsert)
  }

  @Test
  func approvedFetchRefusedAtExecutionShowsDenied() async throws {
    // given
    let fixtures = ApprovedActionExecutorTests()
    let env = try fixtures.makeSuspendedFixture()
    let privateAddress = try #require(ResolvedAddress.parse("10.0.0.5"))
    let fetch = WebFetchTool(
      http: RecordingHTTPExecutor(),
      resolver: ScriptedResolver(table: ["intranet.example": [privateAddress]]),
      redactor: SecretRedactor(secretValues: [])
    )
    let executor = fixtures.makeExecutor(env, tools: [fetch])
    let approval = fixtures.approval(
      env,
      tool: BuiltinToolNames.webFetch,
      argsJSON: #"{"url":"https://intranet.example/"}"#,
      target: "https://intranet.example/",
      reason: .exfilTrifecta
    )
    let display = DispatchProgressState()
    display.releaseIdentification.open()

    // when
    let outcome = await executor.executeApproved(approval, progress: display.reporter)

    // then
    #expect(outcome == .committed)
    #expect(await display.latest.steps.first?.state == .denied)
  }
}
