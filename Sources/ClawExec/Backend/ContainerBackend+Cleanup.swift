import ClawCore
import Foundation

// MARK: - Shielded Cleanup

extension ContainerBackend {
  func runShieldedCleanup(
    identity: ExecutionIdentity,
    workspace: ScratchWorkspace
  ) async -> Bool {
    let commands = commands
    let watchdogSleep = watchdogSleep
    let taskIdentifier = UUID()

    let cleanup = Task.detached {
      await CleanupOperation(
        commands: commands,
        identity: identity.name,
        workspace: workspace,
        watchdogSleep: watchdogSleep
      ).run()
    }

    cleanupTasks[taskIdentifier] = cleanup
    let succeeded = await cleanup.value
    cleanupTasks[taskIdentifier] = nil

    return succeeded
  }
}

private struct CleanupOperation: Sendable {
  let commands: any ContainerCommandRunning
  let identity: String
  let workspace: ScratchWorkspace
  let watchdogSleep: @Sendable (Duration) async throws -> Void

  // The teardown ladder is shielded from cancellation and each command keeps its own
  // `lifecycleCommandTimeout` independent of the run's outer deadline, so a wedged or cancelled
  // execution still tears its VM down instead of orphaning it (ARCHITECTURE.md §13 return bound).
  func run() async -> Bool {
    for step in ContainerInvocation.teardownLadder(identity) {
      _ = await runLifecycle(step)
    }

    let absent = await finalAbsence()

    do {
      try workspace.remove()
    } catch {
      return false
    }

    return absent
  }

  private func runLifecycle(_ arguments: [String]) async -> Bool {
    let result = await ContainerBackend.runControlCommand(
      arguments,
      timeout: ContainerBackend.lifecycleCommandTimeout,
      commands: commands,
      watchdogSleep: watchdogSleep
    )
    return ContainerBackend.successOutput(of: result) != nil
  }

  // Cleanup deliberately keeps the full per-command timeout (not the run's outer deadline,
  // which may already be exhausted) so a wedged execution still gets its teardown attempts.
  private func finalAbsence() async -> Bool {
    guard
      let containers = await ContainerBackend.fetchContainerList(
        timeout: ContainerBackend.lifecycleCommandTimeout,
        commands: commands,
        watchdogSleep: watchdogSleep
      )
    else {
      return false
    }
    return !containers.contains { $0.resolvedIdentifier == identity }
  }
}
