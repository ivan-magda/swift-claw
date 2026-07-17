import Testing

@testable import ClawTelegram

// MARK: - Doubles

/// A stand-in client the factory builds by role, so a test reads which role each slot received and
/// drives close order without a real socket.
private struct RecordingClient: Sendable {
  let role: RuntimeHTTPClientRole
  let close: @Sendable () async -> Void
}

@Suite struct RuntimeHTTPClientsTests {
  @Test func buildsThreeClientsInFixedOrderWithDistinctProfiles() {
    // given — a maker recording the role of every client it is asked to build
    var creationOrder: [RuntimeHTTPClientRole] = []

    // when
    let clients = RuntimeHTTPClients { role in
      creationOrder.append(role)
      return RecordingClient(role: role, close: {})
    }

    // then — Telegram, then LLM, then tool, each in its own slot
    #expect(creationOrder == [.telegram, .llm, .tool])
    #expect(clients.telegram.role == .telegram)
    #expect(clients.llm.role == .llm)
    #expect(clients.tool.role == .tool)
  }

  @Test func telegramFollowsRedirectsWhileLLMAndToolAreProtected() {
    // given / when / then — the three distinct client identities: Telegram on its redirect-following
    // profile, LLM and tool on the protected redirect-disabled one so no bearer can follow a hop
    #expect(RuntimeHTTPClientRole.telegram.egressProfile == .telegram)
    #expect(RuntimeHTTPClientRole.llm.egressProfile == .protectedEgress)
    #expect(RuntimeHTTPClientRole.tool.egressProfile == .protectedEgress)
  }

  @Test func liveBuildsThreeIndependentClosableClients() async throws {
    // given / when — the production bundle over real AsyncHTTPClient-backed clients
    let clients = RuntimeHTTPClients.live()

    // then — three distinct closers, each shutting its own client down cleanly
    try await clients.llm.close()
    try await clients.telegram.close()
    try await clients.tool.close()
  }
}
