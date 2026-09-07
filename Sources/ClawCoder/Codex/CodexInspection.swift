import ClawCore
import Foundation

struct CodexInspection: Sendable {
  let context: CodexCommandContext

  func inspect(
    _ outcome: inout CodexOutcome,
    invocation: CoderInvocation
  ) async throws {
    guard let workspace = outcome.workspace else {
      return
    }
    let git = CoderGit(tracking: context.tracking, phase: .inspect, deadline: context.deadline)
    let identity = try await CoderRequestPreparer.localIdentity(at: workspace.directory, git: git)
    let expected = URL(fileURLWithPath: workspace.directory).resolvingSymlinksInPath().path
    guard identity.checkout == expected else {
      throw CoderError.unavailable("Coder destination is not the expected Git repository root.")
    }
    if let baseline = workspace.baseline {
      do {
        let current = try await RepositoryInventory.capture(at: workspace.directory, git: git)
        outcome.changedFiles = current.changedPaths(comparedWith: baseline)
      } catch RepositoryInventory.Failure.unavailable {
        outcome.changedFiles = nil
      } catch CoderGitFailure.command {
        outcome.changedFiles = nil
      } catch CoderGitFailure.output {
        outcome.changedFiles = nil
      }
    }
    do {
      outcome.branch = try await git.text(
        ["symbolic-ref", "--short", "HEAD"],
        at: workspace.directory
      )
    } catch CoderGitFailure.command {
      outcome.branch = nil
    }
    outcome.commit = try await git.headCommit(at: workspace.directory)
    if outcome.commit != nil {
      outcome.commitAuthor = try await git.text(
        ["show", "--no-patch", "--format=%an <%ae>", "HEAD", "--"],
        at: workspace.directory
      )
    }
    if invocation.prepared.request.deliverable == .pullRequest {
      try await inspectPublication(&outcome, invocation: invocation)
    }
  }
}

// MARK: - Read-only publication evidence

private extension CodexInspection {
  func inspectPublication(_ outcome: inout CodexOutcome, invocation: CoderInvocation) async throws {
    guard let report = outcome.report, let reportedURL = report.prURL,
      let repository = invocation.prepared.publicationRepository,
      let number = pullNumber(reportedURL, repository: repository),
      let head = outcome.branch, head == report.branch, let commit = outcome.commit
    else {
      throw CoderError.unavailable("PR publication could not be independently confirmed.")
    }
    let executable = try CodexInvocation.resolve("gh", environment: context.environment)
    let expectedBase: String
    if let requested = invocation.prepared.request.baseBranch {
      expectedBase = requested
    } else {
      let data = try await context.capture(
        executable: executable,
        arguments: ["repo", "view", repository, "--json", "defaultBranchRef"]
      )
      expectedBase = try JSONDecoder().decode(Repository.self, from: data).defaultBranchRef.name
    }
    guard !expectedBase.isEmpty, report.baseBranch == expectedBase else {
      throw CoderError.unavailable("Reported PR base does not match the selected repository base.")
    }
    let data = try await context.capture(
      executable: executable,
      arguments: [
        "pr", "view", number, "--repo", repository, "--json",
        "url,headRefName,headRefOid,baseRefName,author",
      ]
    )
    let pull = try JSONDecoder().decode(Pull.self, from: data)
    guard pullNumber(pull.url, repository: repository) == number,
      pull.headRefName == head, pull.headRefOid == commit, pull.baseRefName == expectedBase
    else {
      throw CoderError.unavailable("GitHub PR evidence does not match repository, head and base.")
    }
    outcome.publication = .confirmed(url: pull.url)
    outcome.githubActor = pull.author.login
  }

  func pullNumber(_ raw: String, repository: String) -> String? {
    guard let url = URLComponents(string: raw), url.scheme == "https",
      url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
      url.port == nil, url.query == nil, url.fragment == nil,
      url.percentEncodedPath == url.path
    else {
      return nil
    }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 5, parts[0].isEmpty, parts[3] == "pull",
      "\(parts[1])/\(parts[2])".lowercased() == repository,
      !parts[4].isEmpty, parts[4].allSatisfy(\.isNumber), let number = Int(parts[4]), number > 0
    else {
      return nil
    }
    return String(number)
  }

  struct Repository: Decodable {
    struct Branch: Decodable { let name: String }

    let defaultBranchRef: Branch
  }

  struct Pull: Decodable {
    struct Author: Decodable { let login: String }

    let url: String
    let headRefName: String
    let headRefOid: String
    let baseRefName: String
    let author: Author
  }
}
