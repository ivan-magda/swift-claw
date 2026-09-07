import ClawCore
import Foundation

public actor ScriptedCoderBackend: CoderBackend {
  public final class Invocation: Sendable {
    public let entered = AsyncGate()
    public let allowLaunch = AsyncGate()
    public let started = AsyncGate()
    public let cleanupEntered = AsyncGate()
    public let allowCompletion = AsyncGate()
    public let allowCleanup = AsyncGate()
    public let result: CoderResult
    public let unresolvedCleanup: Bool

    public init(
      result: CoderResult,
      holdCleanup: Bool = false,
      unresolvedCleanup: Bool = false,
      holdLaunch: Bool = false
    ) {
      self.result = result
      self.unresolvedCleanup = unresolvedCleanup
      if !holdLaunch { allowLaunch.open() }
      if !holdCleanup { allowCleanup.open() }
    }

    public func release() {
      allowLaunch.open()
      allowCompletion.open()
      allowCleanup.open()
    }

    deinit { release() }
  }

  nonisolated public let invocations: [Invocation]
  nonisolated public var started: AsyncGate { invocations[0].started }
  nonisolated public var allowCompletion: AsyncGate { invocations[0].allowCompletion }
  nonisolated public var allowCleanup: AsyncGate { invocations[0].allowCleanup }
  public private(set) var startedJobIDs: [UUID] = []

  public init(invocations: [Invocation]) {
    precondition(!invocations.isEmpty)
    self.invocations = invocations
  }

  nonisolated public func releaseAll() {
    for invocation in invocations { invocation.release() }
  }

  public func run(
    _ invocation: CoderInvocation,
    recordProcess: @Sendable (CoderProcessEvent) async throws -> Void
  ) async -> CoderResult {
    let index = startedJobIDs.count
    startedJobIDs.append(invocation.jobID)
    let script = invocations[min(index, invocations.count - 1)]
    script.entered.open()
    await script.allowLaunch.waitIgnoringCancellation()
    let launchID = UUID()
    let pending = CoderProcessReceipt(
      launchID: launchID,
      phase: .codex,
      hostBootID: "scripted-boot",
      pid: nil,
      pgid: nil,
      birthIdentity: nil
    )
    let receipt = CoderProcessReceipt(
      launchID: launchID,
      phase: .codex,
      hostBootID: pending.hostBootID,
      pid: 123,
      pgid: 123,
      birthIdentity: "scripted-birth"
    )
    do {
      try await recordProcess(.willLaunch(pending))
      try await recordProcess(.didLaunch(receipt))
      script.started.open()
      await script.allowCompletion.wait()
      script.cleanupEntered.open()
      await script.allowCleanup.waitIgnoringCancellation()
      let event: CoderProcessEvent =
        script.unresolvedCleanup
        ? .unresolved(launchID: launchID) : .stopped(launchID: launchID)
      try await recordProcess(event)
    } catch {
      script.started.open()
    }
    return script.result
  }
}
