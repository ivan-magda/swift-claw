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

/// What composition hands `RunCommand` in place of a bare `Daemon`: the service graph plus the two
/// live pieces the shutdown sequence must own — the exact lane registry it drains and the exact
/// credential sources whose rotation it commits — and the outcome the lane-admission service records.
/// Carrying these here is what lets `RunCommand` sequence credential and client teardown after the
/// lanes quiesce without composition having to leak its internals one accessor at a time.
public struct DaemonRuntimeBundle: Sendable {
  public let daemon: Daemon
  public let lanes: SessionLaneRegistry
  public let credentialSources: [any LLMCredentialSource]
  public let laneShutdownOutcome: LaneShutdownOutcome

  public init(
    daemon: Daemon,
    lanes: SessionLaneRegistry,
    credentialSources: [any LLMCredentialSource],
    laneShutdownOutcome: LaneShutdownOutcome
  ) {
    self.daemon = daemon
    self.lanes = lanes
    self.credentialSources = credentialSources
    self.laneShutdownOutcome = laneShutdownOutcome
  }
}
