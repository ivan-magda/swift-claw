import Foundation

public enum CoderPublication: Sendable, Equatable, Codable {
  case absent
  case confirmed(url: String)
  case unknown(reportedURL: String?)
}

public enum CoderFailureStage: String, Sendable, Codable {
  case preparation, launch, permission, execution, protocolOutput, inspection, cleanup, interrupted
}

public struct CoderFailure: Sendable, Equatable, Codable {
  public let stage: CoderFailureStage
  public let message: String

  public init(
    stage: CoderFailureStage,
    message: String
  ) {
    self.stage = stage
    self.message = message
  }
}

// swiftlint:disable discouraged_optional_collection
/// Nil comparison or usage evidence means unavailable, not an observed empty result.
public struct CoderResult: Sendable, Equatable, Codable {
  public let state: CoderJobState
  public let summary: String
  public let workspacePath: String?
  public let startingCommit: String?
  public let baselineObserved: Bool
  public let changedFiles: [String]?
  public let branch: String?
  public let commit: String?
  public let publication: CoderPublication
  public let reportedChecks: [String]
  public let reportedUsage: [String: Int]?
  public let commitAuthor: String?
  public let githubActor: String?
  public let failure: CoderFailure?

  public init(
    state: CoderJobState,
    summary: String,
    workspacePath: String?,
    startingCommit: String?,
    baselineObserved: Bool,
    changedFiles: [String]?,
    branch: String?,
    commit: String?,
    publication: CoderPublication,
    reportedChecks: [String],
    reportedUsage: [String: Int]?,
    commitAuthor: String?,
    githubActor: String?,
    failure: CoderFailure?
  ) {
    self.state = state
    self.summary = summary
    self.workspacePath = workspacePath
    self.startingCommit = startingCommit
    self.baselineObserved = baselineObserved
    self.changedFiles = changedFiles
    self.branch = branch
    self.commit = commit
    self.publication = publication
    self.reportedChecks = reportedChecks
    self.reportedUsage = reportedUsage
    self.commitAuthor = commitAuthor
    self.githubActor = githubActor
    self.failure = failure
  }
}

// swiftlint:enable discouraged_optional_collection
