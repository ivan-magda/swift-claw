import ClawAgent
import ClawCore
import Logging

/// Sequences dependent-resource teardown after the lanes have quiesced, in the one mandated order.
/// It is library-testable: composition injects the credential-commit and client-close closures, so
/// the ordering, the credential-error precedence rule, and the fatal-timeout refusal are all proven
/// without a real HTTP client or provider.
public struct RuntimeShutdownCoordinator: Sendable {
  /// What the caller does next. `failed` carries the one error to re-raise so the supervisor
  /// restarts; `fatalLaneTimeout` means dependent cleanup was refused and the caller must exit
  /// before any scope unwinds.
  public enum Outcome: Sendable {
    case clean
    case failed(any Error)
    case fatalLaneTimeout(activeRunIDs: [Int64])
  }

  public typealias CleanupStep = @Sendable () async throws -> Void

  /// The dependent-resource teardown closures, in the order they must run: commit the credential
  /// rotation, then close the dedicated LLM client, then the independent Telegram and tool clients.
  /// Grouped so composition hands the coordinator one owned unit rather than four loose closures.
  public struct DependentCleanup: Sendable {
    public let commitCredentials: CleanupStep
    public let closeLLMClient: CleanupStep
    public let closeTelegramClient: CleanupStep
    public let closeToolClient: CleanupStep

    public init(
      commitCredentials: @escaping CleanupStep,
      closeLLMClient: @escaping CleanupStep,
      closeTelegramClient: @escaping CleanupStep,
      closeToolClient: @escaping CleanupStep
    ) {
      self.commitCredentials = commitCredentials
      self.closeLLMClient = closeLLMClient
      self.closeTelegramClient = closeTelegramClient
      self.closeToolClient = closeToolClient
    }
  }

  private let logger: Logger
  private let redactor: SecretRedactor

  public init(logger: Logger, redactor: SecretRedactor) {
    self.logger = logger
    self.redactor = redactor
  }

  /// Runs credential commit, then the LLM, Telegram, and tool client closes — each exactly once,
  /// even when an earlier step throws — but only after a clean lane drain. On a lane timeout it
  /// refuses all of that and returns the active run IDs for the fatal boundary: tearing credentials
  /// or clients down under still-running turns is the exact hazard that path exists to avoid.
  public func shutDown(
    daemonError: (any Error)?,
    laneDrain: SessionLaneDrainResult,
    dependent: DependentCleanup
  ) async -> Outcome {
    if case .timedOut(let activeRunIDs) = laneDrain {
      return .fatalLaneTimeout(activeRunIDs: activeRunIDs)
    }

    // A daemon failure already owns the exit; the credential error only fills a vacant slot.
    var runFailure = daemonError

    do {
      try await dependent.commitCredentials()
    } catch {
      // Redact before logging: a refresh/rotation error can carry token material.
      logger.error("credential shutdown failed: \(redactor.redact("\(error)"))")
      if runFailure == nil {
        runFailure = error
      }
    }

    // Clients close regardless of the credential outcome; a close failure is logged, never promoted
    // to the run failure (an already-torn-down client is not a reason to restart).
    await close(dependent.closeLLMClient, named: "llm")
    await close(dependent.closeTelegramClient, named: "telegram")
    await close(dependent.closeToolClient, named: "tool")

    if let runFailure {
      return .failed(runFailure)
    }
    return .clean
  }
}

// MARK: - Client Teardown

private extension RuntimeShutdownCoordinator {
  func close(_ step: CleanupStep, named name: String) async {
    do {
      try await step()
    } catch {
      logger.error("\(name) client shutdown failed: \(redactor.redact("\(error)"))")
    }
  }
}
