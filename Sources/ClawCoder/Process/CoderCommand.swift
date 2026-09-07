import ClawCore
import Foundation

struct CoderCommand: Sendable {
  let executable: String
  let arguments: [String]
  let environment: [String: String]
  let workingDirectory: String
  let input: String
  let phase: CoderProcessPhase
  let timeout: Duration
}

struct CoderCommandResult: Sendable {
  let exitCode: Int32?
  let signal: Int32?
  let cancelled: Bool
  let timedOut: Bool
  let cleanupResolved: Bool
  let supervisionFailed: Bool
  let diagnostics: String
}

struct CoderScopedCapture: Sendable {
  let cancelled: Bool
  let timedOut: Bool
  let cleanupResolved: Bool
  let supervisionFailed: Bool
  let diagnostics: String
}

enum CoderCommandTracking: Sendable {
  case preApprovalReadOnly
  case job(record: @Sendable (CoderProcessEvent) async throws -> Void)

  func record(_ event: CoderProcessEvent) async throws {
    if case .job(let record) = self { try await record(event) }
  }
}
