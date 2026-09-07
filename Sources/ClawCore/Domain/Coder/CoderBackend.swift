import Foundation

public struct CoderInvocation: Sendable {
  public let jobID: UUID
  public let prepared: CoderPreparedRequest
  public let jobDirectory: String
  public let timeout: Duration

  public init(
    jobID: UUID,
    prepared: CoderPreparedRequest,
    jobDirectory: String,
    timeout: Duration
  ) {
    self.jobID = jobID
    self.prepared = prepared
    self.jobDirectory = jobDirectory
    self.timeout = timeout
  }
}

public protocol CoderBackend: Sendable {
  func run(
    _ invocation: CoderInvocation,
    recordProcess: @Sendable (CoderProcessEvent) async throws -> Void
  ) async -> CoderResult
}

public enum CoderRecoveryObservation: Sendable, Equatable {
  case stopped, liveOwned, unresolved
}

public protocol CoderProcessInspecting: Sendable {
  func inspect(_ receipt: CoderProcessReceipt) async -> CoderRecoveryObservation
}

public protocol CoderRequestPreparing: Sendable {
  func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest
}

public protocol CoderServing: Sendable {
  func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest
  func submit(_ prepared: CoderPreparedRequest, context: ToolExecutionContext) async throws
    -> CoderJob
  func status(id: UUID, context: ToolExecutionContext) async throws -> CoderJob
  func cancel(id: UUID, context: ToolExecutionContext) async throws -> CoderJob
}
