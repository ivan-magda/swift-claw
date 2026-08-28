import ClawAuth

/// A finite OAuth-refresh script. Past its final result it fails instead of spinning, so an
/// unexpected extra refresh is observable.
public actor ScriptedChatGPTOAuthRefresh: ChatGPTOAuthRefreshing {
  public enum Hold: Sendable {
    case none
    case reportingCancellation(AsyncGate)
    case answeringAfterCancellation(AsyncGate)
    case ignoringCancellation(AsyncGate)
  }

  private var script: [Result<ChatGPTTokenPair, ChatGPTOAuthFailure>]
  private let hold: Hold
  public private(set) var tokensSeen: [String] = []
  public let started = AsyncGate()

  public init(
    _ script: [Result<ChatGPTTokenPair, ChatGPTOAuthFailure>] = [],
    hold: Hold = .none
  ) {
    self.script = script
    self.hold = hold
  }

  public var callCount: Int { tokensSeen.count }

  public func refresh(refreshToken: String, timeout: Duration) async throws -> ChatGPTTokenPair {
    tokensSeen.append(refreshToken)
    started.open()
    switch hold {
    case .none:
      break
    case .reportingCancellation(let gate):
      await Self.waitWithBackstop(on: gate)
      try Task.checkCancellation()
    case .answeringAfterCancellation(let gate):
      await Self.waitWithBackstop(on: gate)
    case .ignoringCancellation(let gate):
      await gate.waitIgnoringCancellation()
    }
    guard script.isEmpty == false else {
      throw ChatGPTOAuthFailure.grantRejected(detail: "unscripted refresh")
    }
    return try script.removeFirst().get()
  }

  private static let backstop = Duration.seconds(5)

  private static func waitWithBackstop(on gate: AsyncGate) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await gate.wait()
      }
      group.addTask {
        try? await ContinuousClock().sleep(for: backstop)
      }
      await group.next()
      group.cancelAll()
    }
  }
}
