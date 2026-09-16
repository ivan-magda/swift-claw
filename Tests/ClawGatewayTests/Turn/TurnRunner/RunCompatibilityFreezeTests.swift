import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData
@testable import ClawGateway

/// A run's compatibility surface is frozen at pickup, not read back at sealing. Without this hop
/// every bound run seals with no surface at all, and the whole learning loop degrades to
/// `insufficient_evidence` in silence.
@Suite
struct RunCompatibilityFreezeTests {
  @Test
  func pickupFreezesTheSurfaceAgainstTheRunsOwnPolicyVersion() async throws {
    // given
    let recorder = SurfaceFreezeRecorder()
    let env = try makeEnv(
      agentOutcome: .respond(
        ChatResponse(
          content: "done",
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
          costFromProvider: 0.0021
        )
      ),
      freezeLearningSurface: { runID, policyVersion in
        recorder.record(runID: runID, policyVersion: policyVersion)
      }
    )

    // when
    try await env.runner.run(
      runID: env.runID,
      sessionID: env.sessionID,
      chatID: env.chatID,
      triggerMessageID: env.triggerMessageID
    )

    // then — once, for this run, against the exact version the same pickup stamped on it
    let stamped = try await env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT policy_version FROM runs WHERE id = ?",
        arguments: [env.runID]
      )
    }
    #expect(recorder.calls.count == 1)
    #expect(recorder.calls.first?.runID == env.runID)
    #expect(recorder.calls.first?.policyVersion == stamped)
  }
}

// MARK: - Doubles

/// The freeze hop is a synchronous `@Sendable` closure, so the recorder is lock-guarded rather than
/// an actor.
private final class SurfaceFreezeRecorder: @unchecked Sendable {
  struct Call: Equatable {
    let runID: Int64
    let policyVersion: String
  }

  private let lock = NSLock()
  private var recorded: [Call] = []

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record(runID: Int64, policyVersion: String) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(Call(runID: runID, policyVersion: policyVersion))
  }
}
