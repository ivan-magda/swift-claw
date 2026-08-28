import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationWorkerLifecycleTests {
  @Test func workerLifecycleOwnsTheProductionLockAndShutsDownInOrder() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state")
    let events = LifecycleEvents()

    // when
    let value = try await EvaluationWorkerLifecycle.withProductionLock(
      stateRoot: stateRoot,
      makeResource: {
        let lockPath = stateRoot.appendingPathComponent("clawd.lock").path
        do {
          let unexpected = try InstanceLock(path: lockPath)
          unexpected.release()
          await events.append("resource_without_lock")
        } catch InstanceLock.LockError.alreadyLocked {
          await events.append("resource_under_lock")
        }
        return RecordingLifecycleResource(events: events)
      },
      operation: { _, _ in
        await events.append("operation")
        return 7
      }
    )
    let reacquired = try InstanceLock(path: stateRoot.appendingPathComponent("clawd.lock").path)
    reacquired.release()

    // then
    #expect(value == 7)
    #expect(
      await events.values
        == ["resource_under_lock", "operation", "credentials_closed", "transport_closed"]
    )
  }

  @Test func operationAndCredentialShutdownFailureStillClosesTransportAndFailsIntegrity() async {
    // given
    let events = LifecycleEvents()

    // when
    let error = await #expect(throws: EvaluationWorkerLifecycleError.self) {
      _ = try await EvaluationWorkerLifecycle.withResource(
        makeResource: { FailingLifecycleResource(events: events) },
        operation: { _ -> Int in
          await events.append("operation_failed")
          throw LifecycleTestError.operation
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(
      await events.values
        == ["operation_failed", "credentials_failed", "transport_closed"]
    )
  }
}

private actor LifecycleEvents {
  private var stored: [String] = []

  var values: [String] { stored }

  func append(_ value: String) {
    stored.append(value)
  }
}

private struct RecordingLifecycleResource: EvaluationWorkerResource {
  let events: LifecycleEvents

  func shutdownCredentials() async throws {
    await events.append("credentials_closed")
  }

  func shutdownTransport() async throws {
    await events.append("transport_closed")
  }
}

private enum LifecycleTestError: Error {
  case operation
  case credentials
}

private struct FailingLifecycleResource: EvaluationWorkerResource {
  let events: LifecycleEvents

  func shutdownCredentials() async throws {
    await events.append("credentials_failed")
    throw LifecycleTestError.credentials
  }

  func shutdownTransport() async throws {
    await events.append("transport_closed")
  }
}
