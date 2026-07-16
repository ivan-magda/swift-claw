import ClawAgent
import ClawCore
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct RuntimeShutdownCoordinatorTests {
  @Test func runsCleanupInMandatedOrderOnCleanDrain() async throws {
    // given
    let recorder = StepRecorder()
    let coordinator = Self.coordinator()

    // when
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: .drained,
      dependent: Self.recordingCleanup(into: recorder)
    )

    // then — the exact golden sequence; a reordered or skipped step fails this list equality.
    #expect(await recorder.events == ["credential", "llm", "telegram", "tool"])
    #expect(Self.isClean(outcome))
  }

  @Test func skipsDependentCleanupAndReturnsRunIDsOnLaneTimeout() async throws {
    // given
    let recorder = StepRecorder()
    let coordinator = Self.coordinator()

    // when
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: .timedOut(activeRunIDs: [5, 9]),
      dependent: Self.recordingCleanup(into: recorder)
    )

    // then — steps 3-5 are refused entirely, and the active run IDs are handed back untouched.
    #expect(await recorder.events == [])
    guard case .fatalLaneTimeout(let activeRunIDs) = outcome else {
      Issue.record("expected fatalLaneTimeout, got \(outcome)")
      return
    }
    #expect(activeRunIDs == [5, 9])
  }

  @Test func credentialErrorBecomesTheFailureWhenNoDaemonErrorExists() async throws {
    // given
    let recorder = StepRecorder()
    let coordinator = Self.coordinator()

    // when
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: .drained,
      dependent: Self.recordingCleanup(into: recorder, credentialError: CredentialFault())
    )

    // then — client shutdown still runs, and the credential error is the run failure.
    #expect(await recorder.events == ["credential", "llm", "telegram", "tool"])
    guard case .failed(let error) = outcome else {
      Issue.record("expected failed, got \(outcome)")
      return
    }
    #expect(error is CredentialFault)
  }

  @Test func credentialErrorDoesNotDisplaceAnEarlierDaemonError() async throws {
    // given
    let recorder = StepRecorder()
    let coordinator = Self.coordinator()

    // when
    let outcome = await coordinator.shutDown(
      daemonError: DaemonFault(),
      laneDrain: .drained,
      dependent: Self.recordingCleanup(into: recorder, credentialError: CredentialFault())
    )

    // then — every step still runs, but the pre-existing daemon error owns the exit.
    #expect(await recorder.events == ["credential", "llm", "telegram", "tool"])
    guard case .failed(let error) = outcome else {
      Issue.record("expected failed, got \(outcome)")
      return
    }
    #expect(error is DaemonFault)
  }

  @Test func eachCleanupClosureRunsOnceEvenWhenAnEarlierOneThrows() async throws {
    // given
    let recorder = StepRecorder()
    let coordinator = Self.coordinator()

    // when — the LLM close throws; the remaining closes must still each run exactly once.
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: .drained,
      dependent: Self.recordingCleanup(into: recorder, llmError: ClientFault())
    )

    // then — order preserved, no step repeated, and a client-close error is not promoted to failure.
    #expect(await recorder.events == ["credential", "llm", "telegram", "tool"])
    #expect(Self.isClean(outcome))
  }

  @Test func redactsTheCredentialErrorBeforeLogging() async throws {
    // given
    let secret = "sk-live-credential-secret-xyz"
    let capture = ShutdownLogCapture()
    let coordinator = RuntimeShutdownCoordinator(
      logger: Logger(label: "test") { _ in
        CapturingLogHandler(capture: capture)
      },
      redactor: SecretRedactor(secretValues: [secret])
    )

    // when
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: .drained,
      dependent: RuntimeShutdownCoordinator.DependentCleanup(
        commitCredentials: { throw SecretBearingFault(secret: secret) },
        closeLLMClient: {},
        closeTelegramClient: {},
        closeToolClient: {}
      )
    )

    // then — the secret never reaches the log; its redaction marker does.
    let logged = capture.messages.joined(separator: "\n")
    #expect(!logged.contains(secret))
    #expect(logged.contains(SecretRedactor.replacement))
    guard case .failed = outcome else {
      Issue.record("expected failed, got \(outcome)")
      return
    }
  }

  private static func coordinator() -> RuntimeShutdownCoordinator {
    RuntimeShutdownCoordinator(logger: TestLog.silent, redactor: SecretRedactor(secretValues: []))
  }

  /// Cleanup closures that record their step name in order; an optional error lets a test throw from
  /// the credential commit or the LLM close after recording, so a throwing step still proves it ran.
  private static func recordingCleanup(
    into recorder: StepRecorder,
    credentialError: (any Error)? = nil,
    llmError: (any Error)? = nil
  ) -> RuntimeShutdownCoordinator.DependentCleanup {
    RuntimeShutdownCoordinator.DependentCleanup(
      commitCredentials: {
        await recorder.record("credential")
        if let credentialError {
          throw credentialError
        }
      },
      closeLLMClient: {
        await recorder.record("llm")
        if let llmError {
          throw llmError
        }
      },
      closeTelegramClient: { await recorder.record("telegram") },
      closeToolClient: { await recorder.record("tool") }
    )
  }

  private static func isClean(_ outcome: RuntimeShutdownCoordinator.Outcome) -> Bool {
    if case .clean = outcome {
      return true
    }
    return false
  }
}

private actor StepRecorder {
  private(set) var events: [String] = []

  func record(_ name: String) {
    events.append(name)
  }
}

private struct CredentialFault: Error {}
private struct DaemonFault: Error {}
private struct ClientFault: Error {}

private struct SecretBearingFault: Error, CustomStringConvertible {
  let secret: String
  var description: String { "rotation publish failed with token \(secret)" }
}

private final class ShutdownLogCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func append(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(message)
  }
}

private struct CapturingLogHandler: LogHandler {
  let capture: ShutdownLogCapture
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(
    level: Logger.Level,
    message: Logger.Message,
    metadata: Logger.Metadata?,
    source: String,
    file: String,
    function: String,
    line: UInt
  ) {
    capture.append("\(message)")
  }
}
