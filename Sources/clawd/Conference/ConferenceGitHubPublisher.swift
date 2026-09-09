import ClawCore
import ClawSubprocess
import Foundation

struct ConferenceGitHubPublisher: ConferencePublishing {
  private let stateRoot: URL
  private let token: String
  private let expectedActor: String
  private let http: any HTTPExecuting
  private let git: SwiftSubprocessRunner

  init(
    stateRoot: URL,
    token: String,
    expectedActor: String,
    http: any HTTPExecuting
  ) throws {
    self.stateRoot = stateRoot.resolvingSymlinksInPath().standardizedFileURL
    self.token = token
    self.expectedActor = expectedActor
    self.http = http

    let publisherHome = stateRoot.appendingPathComponent("conference-publisher", isDirectory: true)
    try FileManager.default.createDirectory(
      at: publisherHome,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let askpass = publisherHome.appendingPathComponent("git-askpass.sh")
    let script = """
      #!/bin/sh
      case "$1" in
        *Username*) printf '%s\\n' 'x-access-token' ;;
        *Password*) printf '%s\\n' "$CLAW_CONFERENCE_GITHUB_TOKEN" ;;
        *) exit 1 ;;
      esac
      """
    try Data(script.utf8).write(to: askpass, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: askpass.path
    )

    git = SwiftSubprocessRunner(
      executablePath: "/usr/bin/git",
      environmentForTesting: [
        "HOME": publisherHome.path,
        "CLAW_CONFERENCE_GITHUB_TOKEN": token,
        "GIT_ASKPASS": askpass.path,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
      ]
    )
  }

  func publish(_ request: ConferencePublicationRequest) async throws -> ConferencePublication {
    let repository = try repositoryIdentity(request.repositoryURL)
    let workspace = try validatedWorkspace(request.workspacePath)
    try await validateCommit(request, workspace: workspace)

    let branch = "conference/\(request.submissionID.uuidString.lowercased())"
    try await push(
      commit: request.commit,
      branch: branch,
      repository: repository,
      workspace: workspace
    )

    if let existing = try await existingPullRequest(
      repository: repository,
      branch: branch,
      base: request.baseBranch
    ) {
      return try validatedPublication(
        existing,
        expectedBranch: branch,
        expectedBase: request.baseBranch,
        expectedCommit: request.commit
      )
    }

    let created = try await createPullRequest(
      request: request,
      repository: repository,
      branch: branch
    )
    return try validatedPublication(
      created,
      expectedBranch: branch,
      expectedBase: request.baseBranch,
      expectedCommit: request.commit
    )
  }
}

// MARK: - Git boundary

private extension ConferenceGitHubPublisher {
  struct RepositoryIdentity {
    let owner: String
    let name: String

    var slug: String { "\(owner)/\(name)" }
    var pushURL: String { "https://github.com/\(slug).git" }
  }

  func repositoryIdentity(_ raw: String) throws -> RepositoryIdentity {
    guard let url = URL(string: raw),
      url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "github.com"
    else {
      throw ConferencePublicationError.invalidRepository
    }
    let components = url.path.split(separator: "/").map(String.init)
    guard components.count == 2 else {
      throw ConferencePublicationError.invalidRepository
    }
    let name =
      components[1].hasSuffix(".git")
      ? String(components[1].dropLast(4))
      : components[1]
    guard validRepositoryPart(components[0]), validRepositoryPart(name) else {
      throw ConferencePublicationError.invalidRepository
    }
    return RepositoryIdentity(owner: components[0], name: name)
  }

  func validRepositoryPart(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 100
      && value.allSatisfy {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
      }
  }

  func validatedWorkspace(_ raw: String) throws -> String {
    let workspace = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
    let jobs = stateRoot.appendingPathComponent("coder/jobs", isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    let prefix = jobs.path.hasSuffix("/") ? jobs.path : jobs.path + "/"
    guard workspace.path.hasPrefix(prefix) else {
      throw ConferencePublicationError.invalidWorkspace
    }
    return workspace.path
  }

  func validateCommit(
    _ request: ConferencePublicationRequest,
    workspace: String
  ) async throws {
    guard validCommit(request.startingCommit),
      validCommit(request.commit),
      request.startingCommit != request.commit
    else {
      throw ConferencePublicationError.invalidCommit
    }
    let head = try await gitOutput(["-C", workspace, "rev-parse", "--verify", "HEAD^{commit}"])
    guard head == request.commit else {
      throw ConferencePublicationError.invalidCommit
    }
    try await gitSuccess([
      "-C", workspace, "merge-base", "--is-ancestor", request.startingCommit, request.commit,
    ])
    let status = try await gitOutput(["-C", workspace, "status", "--porcelain=v1"])
    guard status.isEmpty else {
      throw ConferencePublicationError.invalidCommit
    }
  }

  func validCommit(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
  }

  func push(
    commit: String,
    branch: String,
    repository: RepositoryIdentity,
    workspace: String
  ) async throws {
    do {
      try await gitSuccess([
        "-c", "credential.helper=",
        "-c", "core.hooksPath=/dev/null",
        "-C", workspace,
        "push", "--no-verify", "--porcelain", "--",
        repository.pushURL,
        "\(commit):refs/heads/\(branch)",
      ])
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ConferencePublicationError.pushFailed
    }
  }

  func gitSuccess(_ arguments: [String]) async throws {
    let result = await git.run(command(arguments))
    if Task.isCancelled || result.termination == .cancelled {
      throw CancellationError()
    }
    guard result.termination == .exited(0), !result.stderr.truncated else {
      throw ConferencePublicationError.invalidCommit
    }
  }

  func gitOutput(_ arguments: [String]) async throws -> String {
    let result = await git.run(command(arguments))
    if Task.isCancelled || result.termination == .cancelled {
      throw CancellationError()
    }
    guard result.termination == .exited(0),
      !result.stdout.truncated,
      let output = String(data: result.stdout.bytes, encoding: .utf8)
    else {
      throw ConferencePublicationError.invalidCommit
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func command(_ arguments: [String]) -> SubprocessCommand {
    SubprocessCommand(
      arguments: arguments,
      timeout: .seconds(60),
      captureLimit: 64 * 1024,
      teardownGracePeriod: .seconds(2),
      environmentKeysToRemove: [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "SSH_AUTH_SOCK",
      ]
    )
  }
}

// MARK: - GitHub API boundary

private extension ConferenceGitHubPublisher {
  struct PullRequest: Decodable {
    struct User: Decodable { let login: String }
    struct Ref: Decodable {
      let ref: String
      let sha: String
    }

    let htmlURL: String
    let user: User
    let head: Ref
    let base: Ref

    enum CodingKeys: String, CodingKey {
      case htmlURL = "html_url"
      case user
      case head
      case base
    }
  }

  struct CreatePullRequest: Encodable {
    let title: String
    let head: String
    let base: String
    let body: String
    let draft: Bool
  }

  func existingPullRequest(
    repository: RepositoryIdentity,
    branch: String,
    base: String
  ) async throws -> PullRequest? {
    var components = URLComponents(
      string: "https://api.github.com/repos/\(repository.slug)/pulls"
    )
    components?.queryItems = [
      URLQueryItem(name: "state", value: "open"),
      URLQueryItem(name: "head", value: "\(repository.owner):\(branch)"),
      URLQueryItem(name: "base", value: base),
    ]
    guard let url = components?.url?.absoluteString else {
      throw ConferencePublicationError.apiFailed
    }
    let result = try await execute(method: .get, url: url, body: nil)
    guard HTTPResponseBodyPolicy.isSuccess(result.statusCode),
      let pulls = try? JSONDecoder().decode([PullRequest].self, from: result.body)
    else {
      throw ConferencePublicationError.apiFailed
    }
    return pulls.first
  }

  func createPullRequest(
    request: ConferencePublicationRequest,
    repository: RepositoryIdentity,
    branch: String
  ) async throws -> PullRequest {
    let body = CreatePullRequest(
      title: """
        Conference Coding Challenge submission \(request.submissionID.uuidString.lowercased())
        """,
      head: branch,
      base: request.baseBranch,
      body: "Generated implementation of the participant's submitted proposal.",
      draft: true
    )
    let data = try JSONEncoder().encode(body)
    let url = "https://api.github.com/repos/\(repository.slug)/pulls"
    let result = try await execute(method: .post, url: url, body: data)
    guard result.statusCode == 201,
      let pull = try? JSONDecoder().decode(PullRequest.self, from: result.body)
    else {
      throw ConferencePublicationError.apiFailed
    }
    return pull
  }

  func execute(method: HTTPMethod, url: String, body: Data?) async throws -> HTTPResult {
    do {
      return try await http.execute(
        HTTPRequest(
          method: method,
          url: url,
          headers: [
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
          ],
          body: body,
          timeout: .seconds(15),
          responseBodyPolicy: .buffered(successBytes: 128 * 1024, errorBytes: 16 * 1024)
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ConferencePublicationError.apiFailed
    }
  }

  func validatedPublication(
    _ pull: PullRequest,
    expectedBranch: String,
    expectedBase: String,
    expectedCommit: String
  ) throws -> ConferencePublication {
    guard pull.head.ref == expectedBranch,
      pull.head.sha == expectedCommit,
      pull.base.ref == expectedBase
    else {
      throw ConferencePublicationError.apiFailed
    }
    guard pull.user.login.caseInsensitiveCompare(expectedActor) == .orderedSame else {
      throw ConferencePublicationError.actorMismatch(
        expected: expectedActor,
        actual: pull.user.login
      )
    }
    return ConferencePublication(
      pullRequestURL: pull.htmlURL,
      branch: expectedBranch,
      commit: expectedCommit,
      actor: pull.user.login
    )
  }
}
