import Foundation

public struct ConferencePublicationRequest: Sendable, Equatable {
  public let submissionID: UUID
  public let proposal: PreparedConferenceSubmission
  public let workspacePath: String
  public let startingCommit: String
  public let commit: String
  public let reportedChecks: [String]

  public var repositoryURL: String { proposal.caseSnapshot.repositoryURL }
  public var baseBranch: String { proposal.caseSnapshot.baseBranch }

  public init(
    submissionID: UUID,
    proposal: PreparedConferenceSubmission,
    workspacePath: String,
    startingCommit: String,
    commit: String,
    reportedChecks: [String]
  ) {
    self.submissionID = submissionID
    self.proposal = proposal
    self.workspacePath = workspacePath
    self.startingCommit = startingCommit
    self.commit = commit
    self.reportedChecks = reportedChecks
  }
}

public struct ConferencePublication: Sendable, Equatable {
  public let pullRequestURL: String
  public let branch: String
  public let commit: String
  public let actor: String

  public init(pullRequestURL: String, branch: String, commit: String, actor: String) {
    self.pullRequestURL = pullRequestURL
    self.branch = branch
    self.commit = commit
    self.actor = actor
  }
}

public protocol ConferencePublishing: Sendable {
  func publish(_ request: ConferencePublicationRequest) async throws -> ConferencePublication
}

public enum ConferencePublicationError: Error, Sendable, Equatable {
  case invalidRepository
  case invalidWorkspace
  case invalidCommit
  case invalidPublication
  case pushFailed
  case apiFailed
  case actorMismatch(expected: String, actual: String)
}
