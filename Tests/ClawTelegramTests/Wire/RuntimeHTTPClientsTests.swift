import ClawHTTP
import Testing

@testable import ClawTelegram

// MARK: - Doubles

/// A stand-in client the factory builds by role, so a test reads which role each slot received.
private struct RecordingClient: Sendable {
  let role: RuntimeHTTPClientRole
}

@Suite
struct RuntimeHTTPClientsTests {
  @Test
  func buildsThreeClientsInFixedOrderWithDistinctProfiles() {
    // given — a maker recording the role of every client it is asked to build
    var creationOrder: [RuntimeHTTPClientRole] = []

    // when
    let clients = RuntimeHTTPClients { role in
      creationOrder.append(role)
      return RecordingClient(role: role)
    }

    // then — Telegram, then LLM, then tool, each in its own slot
    #expect(creationOrder == [.telegram, .llm, .tool])
    #expect(clients.telegram.role == .telegram)
    #expect(clients.llm.role == .llm)
    #expect(clients.tool.role == .tool)
  }

  @Test
  func telegramFollowsRedirectsWhileLLMAndToolAreProtected() {
    // given
    let roles: [RuntimeHTTPClientRole] = [.telegram, .llm, .tool]

    // when
    let profiles = roles.map(\.egressProfile)

    // then
    #expect(profiles == [.redirectFollowing, .protectedEgress, .protectedEgress])
  }
}
