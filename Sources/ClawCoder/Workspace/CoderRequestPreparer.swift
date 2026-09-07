import ClawCore
import Foundation

public struct CoderRequestPreparer: CoderRequestPreparing {
  private let executionPolicyID: String

  public init(executionPolicyID: String) {
    self.executionPolicyID = executionPolicyID
  }

  public func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest {
    let request = try request.validated()
    let source: String
    let checkout: String?
    let common: String?
    let publication: String?
    switch request.source {
    case .local(let path):
      let git = CoderGit(
        tracking: .preApprovalReadOnly,
        phase: .prepare,
        deadline: ContinuousClock.now.advanced(by: .seconds(30))
      )
      do {
        let identity = try await Self.localIdentity(at: path, git: git)
        source = identity.checkout
        checkout = identity.checkout
        common = identity.common
        publication =
          request.deliverable == .pullRequest
          ? try await Self.publicationOrigin(at: identity.checkout, git: git) : nil
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw CoderError.invalidRequest(
          "Cannot resolve local Git checkout or its unambiguous GitHub origin for publication."
        )
      }
    case .githubRepository(let url), .githubIssue(let url):
      let isIssue: Bool
      if case .githubIssue = request.source {
        isIssue = true
      } else {
        isIssue = false
      }
      let repository = try Self.githubRepository(url, issue: isIssue)
      source = "https://github.com/\(repository)"
      checkout = nil
      common = nil
      publication = request.deliverable == .pullRequest ? repository : nil
    }
    return CoderPreparedRequest(
      request: request,
      canonicalSource: source,
      checkoutPath: checkout,
      commonGitDirectory: common,
      executionPolicyID: executionPolicyID,
      publicationRepository: publication
    )
  }
}

// MARK: - Local identity

extension CoderRequestPreparer {
  static func localIdentity(
    at path: String,
    git: CoderGit
  ) async throws -> (checkout: String, common: String) {
    let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    let checkout = try await git.text(["rev-parse", "--show-toplevel"], at: directory)
    let common = try await git.text(
      ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      at: directory
    )
    guard checkout.hasPrefix("/"), common.hasPrefix("/") else {
      throw CoderGitFailure.output
    }
    return (
      URL(fileURLWithPath: checkout).resolvingSymlinksInPath().standardizedFileURL.path,
      URL(fileURLWithPath: common).resolvingSymlinksInPath().standardizedFileURL.path
    )
  }

  static func publicationOrigin(at directory: String, git: CoderGit) async throws -> String {
    let data = try await git.run(
      ["config", "--null", "--get-all", "remote.origin.url"],
      at: directory
    )
    let values = data.split(separator: 0, omittingEmptySubsequences: false)
    guard values.count == 2, !values[0].isEmpty, values[1].isEmpty
    else {
      throw CoderError.invalidRequest("Publication requires one unambiguous GitHub origin URL.")
    }
    let effective = try await git.text(["remote", "get-url", "--all", "origin"], at: directory)
    let push = try await git.text(
      ["remote", "get-url", "--push", "--all", "origin"],
      at: directory
    )
    let repository = try githubRepository(effective)
    guard try githubRepository(push) == repository else {
      throw CoderError.invalidRequest("Publication origin has a conflicting push destination.")
    }
    return repository
  }

  static func githubRepository(_ raw: String, issue: Bool = false) throws -> String {
    var url = raw
    if url.hasPrefix("git@github.com:") {
      url = "https://github.com/" + url.dropFirst("git@github.com:".count)
    } else if url.hasPrefix("ssh://git@github.com/") {
      url = "https://github.com/" + url.dropFirst("ssh://git@github.com/".count)
    }
    guard let components = URLComponents(string: url) else {
      throw CoderError.invalidRequest("Publication requires a GitHub origin URL.")
    }
    let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
    let validation = CoderRequest(
      source: issue ? .githubIssue(url: url) : .githubRepository(url: url),
      task: "identity",
      workspace: .separate,
      startRef: nil,
      deliverable: .localChanges,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    )
    _ = try validation.validated()
    var repository = String(parts[2])
    if repository.hasSuffix(".git") {
      repository.removeLast(4)
    }
    guard !repository.isEmpty, repository != ".", repository != ".." else {
      throw CoderError.invalidRequest("Publication requires a GitHub repository name.")
    }
    return "\(parts[1])/\(repository)".lowercased()
  }
}
