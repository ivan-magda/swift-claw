import AsyncHTTPClient

// MARK: - Roles and profiles

/// Which egress profile a runtime client is built on. Named as a value the factory assigns per role —
/// rather than a bare `HTTPClient.Configuration`, whose redirect posture no test can read back — so a
/// test can prove the LLM and tool clients are the redirect-disabled ones and the Telegram client is
/// not.
public enum RuntimeHTTPEgressProfile: Sendable, Equatable {
  case telegram
  case protectedEgress

  public var configuration: HTTPClient.Configuration {
    switch self {
    case .telegram: return HTTPClientProfile.telegram
    case .protectedEgress: return HTTPClientProfile.protectedEgress
    }
  }
}

/// The three clients a running daemon points at a third party, each an identity of its own. Splitting
/// the LLM client off Telegram is a behavior change, not a rename: the shared Telegram/LLM client
/// followed redirects at the library default, and moving LLM to `protectedEgress` stops LLM traffic
/// following a redirect — the property a subscription bearer needs so it can never be walked to
/// another host. The tool client already used that profile.
public enum RuntimeHTTPClientRole: Sendable, CaseIterable, Equatable {
  case telegram
  case llm
  case tool

  /// The LLM and tool clients share the protected redirect-disabled profile so neither a static nor a
  /// subscription bearer can follow a redirect off its pinned host; Telegram keeps the
  /// redirect-following default it has always used.
  public var egressProfile: RuntimeHTTPEgressProfile {
    switch self {
    case .telegram: return .telegram
    case .llm, .tool: return .protectedEgress
    }
  }
}

// MARK: - Client bundle

/// The three independent runtime clients, built in a fixed, observable order. Generic over the client
/// so the composition root produces live AsyncHTTPClient-backed executors while a test injects a
/// recording maker: the role each client is built for, and thus its egress profile, is then a fact a
/// test reads rather than a promise the wiring makes.
public struct RuntimeHTTPClients<Client: Sendable>: Sendable {
  public let telegram: Client
  public let llm: Client
  public let tool: Client

  /// Builds the three clients by role. The order is fixed — Telegram, then LLM, then tool — so an
  /// injected maker observes the same sequence production creates them in.
  public init(makeClient: (RuntimeHTTPClientRole) throws -> Client) rethrows {
    telegram = try makeClient(.telegram)
    llm = try makeClient(.llm)
    tool = try makeClient(.tool)
  }
}

// MARK: - Live client

/// One live runtime client: the executor its consumer drives, and the idempotent shutdown the cleanup
/// sequence commits. Split so the executor can be handed to a service while the closer stays with the
/// composition root that owns teardown order.
public struct RuntimeHTTPClient: Sendable {
  public let executor: AsyncHTTPExecutor
  public let close: @Sendable () async throws -> Void

  public init(executor: AsyncHTTPExecutor, close: @escaping @Sendable () async throws -> Void) {
    self.executor = executor
    self.close = close
  }
}

extension RuntimeHTTPClients where Client == RuntimeHTTPClient {
  /// The production bundle: three AsyncHTTPClient-backed clients on the singleton event-loop group,
  /// each on its role's egress profile, each with its own executor and shutdown.
  public static func live() -> RuntimeHTTPClients<RuntimeHTTPClient> {
    RuntimeHTTPClients { role in
      let client = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: role.egressProfile.configuration
      )
      return RuntimeHTTPClient(
        executor: AsyncHTTPExecutor(client: client),
        close: { try await client.shutdown() }
      )
    }
  }
}
