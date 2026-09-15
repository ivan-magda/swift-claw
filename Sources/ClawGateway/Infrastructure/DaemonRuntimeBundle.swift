import ClawAgent
import ClawCore

/// The single writer/reader of the lane-drain result across the shutdown boundary. The lane-
/// admission service records exactly one outcome as it drains; `RunCommand` reads it after the
/// service graph returns to decide between a clean stop and the fatal timeout path.
public actor LaneShutdownOutcome {
  private var result: SessionLaneDrainResult?

  public init() {}

  public func record(_ result: SessionLaneDrainResult) {
    self.result = result
  }

  public func value() -> SessionLaneDrainResult? {
    result
  }
}

/// Carries the exact live owners into command shutdown, including Coder work admitted by boot replay.
/// Coder remains available for the final joined-cleanup check before dependent teardown.
public struct DaemonRuntimeBundle: Sendable {
  public let daemon: Daemon
  public let lanes: SessionLaneRegistry
  public let credentialSources: [any LLMCredentialSource]
  public let laneShutdownOutcome: LaneShutdownOutcome
  public let coder: CoderService?

  public init(
    daemon: Daemon,
    lanes: SessionLaneRegistry,
    credentialSources: [any LLMCredentialSource],
    laneShutdownOutcome: LaneShutdownOutcome,
    coder: CoderService? = nil
  ) {
    self.daemon = daemon
    self.lanes = lanes
    self.credentialSources = credentialSources
    self.laneShutdownOutcome = laneShutdownOutcome
    self.coder = coder
  }
}
