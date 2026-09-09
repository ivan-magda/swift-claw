import Foundation

public struct ConferencePublicationRequest: Sendable, Equatable {
  public let submissionID: UUID
  public let repositoryURL: String
  public let baseBranch: String
  public let workspacePath: String
  public let startingCommit: String
  public let commit: String

  public init(
    submissionID: UUID,
    repositoryURL: String,
    baseBranch: String,
    workspacePath: String,
    startingCommit: String,
    commit: String
  ) {
    self.submissionID = submissionID
    self.repositoryURL = repositoryURL
    self.baseBranch = baseBranch
    self.workspacePath = workspacePath
    self.startingCommit = startingCommit
    self.commit = commit
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
  case pushFailed
  case apiFailed
  case actorMismatch(expected: String, actual: String)
}
