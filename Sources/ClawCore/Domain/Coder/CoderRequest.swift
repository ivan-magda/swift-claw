import Foundation

public enum CoderToolNames {
  public static let submit = "coder_submit"
  public static let status = "coder_status"
  public static let cancel = "coder_cancel"
}

public enum CoderWorkspaceMode: String, Sendable, Codable { case inPlace, separate }

public enum CoderDeliverable: String, Sendable, Codable { case localChanges, pullRequest }

public enum CoderSource: Sendable, Equatable, Codable {
  case local(path: String)
  case githubRepository(url: String)
  case githubIssue(url: String)
}

public struct CoderRequest: Sendable, Equatable, Codable {
  public let source: CoderSource
  public let task: String?
  public let workspace: CoderWorkspaceMode
  public let startRef: String?
  public let deliverable: CoderDeliverable
  public let baseBranch: String?
  public let instructions: String?
  public let publishExistingChanges: Bool

  public init(
    source: CoderSource,
    task: String?,
    workspace: CoderWorkspaceMode,
    startRef: String?,
    deliverable: CoderDeliverable,
    baseBranch: String?,
    instructions: String?,
    publishExistingChanges: Bool
  ) {
    self.source = source
    self.task = task
    self.workspace = workspace
    self.startRef = startRef
    self.deliverable = deliverable
    self.baseBranch = baseBranch
    self.instructions = instructions
    self.publishExistingChanges = publishExistingChanges
  }
}

public enum CoderError: Error, Sendable, Equatable {
  case invalidRequest(String)
  case unavailable(String)
  case forbidden
  case busy, workspaceBusy, staleApproval, recoveryRequired
}

public struct CoderPreparedRequest: Sendable, Equatable, Codable {
  public let request: CoderRequest
  public let canonicalSource: String
  public let checkoutPath: String?
  public let commonGitDirectory: String?
  public let executionPolicyID: String
  public let publicationRepository: String?

  public init(
    request: CoderRequest,
    canonicalSource: String,
    checkoutPath: String?,
    commonGitDirectory: String?,
    executionPolicyID: String,
    publicationRepository: String?
  ) {
    self.request = request
    self.canonicalSource = canonicalSource
    self.checkoutPath = checkoutPath
    self.commonGitDirectory = commonGitDirectory
    self.executionPolicyID = executionPolicyID
    self.publicationRepository = publicationRepository
  }
}

// MARK: - Validation

public extension CoderRequest {
  /// Validates task shape without reading the checkout or interpreting task text as commands.
  func validated() throws(CoderError) -> CoderRequest {
    if workspace == .inPlace, startRef != nil {
      throw .invalidRequest("startRef requires a separate copy; in-place keeps its current branch.")
    }
    if workspace == .separate, publishExistingChanges {
      throw .invalidRequest("A separate copy cannot publish existing uncommitted changes.")
    }

    switch source {
    case .local(let path):
      guard path.hasPrefix("/") else {
        throw .invalidRequest("A local source requires an absolute path.")
      }
      try requireTask()
    case .githubRepository(let url):
      try requireRemoteWorkspace()
      try Self.validateGitHubURL(url, issue: false)
      try requireTask()
    case .githubIssue(let url):
      try requireRemoteWorkspace()
      try Self.validateGitHubURL(url, issue: true)
    }
    return self
  }
}

// MARK: - Source Validation

private extension CoderRequest {
  func requireTask() throws(CoderError) {
    guard let task, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw .invalidRequest("A local or GitHub repository source requires a task.")
    }
  }

  func requireRemoteWorkspace() throws(CoderError) {
    guard workspace == .separate else {
      throw .invalidRequest("A GitHub source requires a separate copy.")
    }
  }

  static func validateGitHubURL(_ raw: String, issue: Bool) throws(CoderError) {
    guard
      let url = URLComponents(string: raw),
      url.scheme == "https", url.host == "github.com",
      url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil,
      url.percentEncodedPath == url.path
    else {
      throw .invalidRequest("Use a GitHub HTTPS URL without credentials, port, query or fragment.")
    }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
    let expectedCount = issue ? 5 : 3
    guard
      parts.count == expectedCount, parts[0].isEmpty,
      validRepositoryComponent(parts[1]), validRepositoryComponent(parts[2])
    else {
      throw .invalidRequest("Use github.com/{owner}/{repo} or its /issues/{number} URL.")
    }
    if issue {
      guard
        parts[3] == "issues", !parts[4].isEmpty,
        parts[4].utf8.allSatisfy({ byte in
          (48...57).contains(byte)
        }),
        let number = Int(parts[4]), number > 0
      else {
        throw .invalidRequest("A GitHub issue URL requires a positive issue number.")
      }
    }
  }

  static func validRepositoryComponent(_ value: Substring) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("-"), value != ".", value != ".." else {
      return false
    }
    return value.utf8.allSatisfy { byte in
      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        || byte == 45 || byte == 46 || byte == 95
    }
  }
}
