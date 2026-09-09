import ClawCore
import ClawSubprocess
import Foundation

struct ConferenceGitHubPublisher: ConferencePublishing {
  private let stateRoot: URL
  private let home: URL
  private let token: String
  private let expectedActor: String
  private let http: any HTTPExecuting
  private let git: any SubprocessRunning
  private let pushGit: any SubprocessRunning

  init(
    stateRoot: URL,
    token: String,
    expectedActor: String,
    http: any HTTPExecuting,
    git: (any SubprocessRunning)? = nil,
    pushGit: (any SubprocessRunning)? = nil
  ) throws {
    self.stateRoot = stateRoot.resolvingSymlinksInPath().standardizedFileURL
    self.token = token
    self.expectedActor = expectedActor
    self.http = http
    home = self.stateRoot.appendingPathComponent("conference-publisher", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let askpass = home.appendingPathComponent("git-askpass.sh")
    let script = """
      #!/bin/sh
      case "$1" in
        *Username*) printf '%s\\n' 'x-access-token' ;;
        *Password*) printf '%s\\n' "$CLAW_CONFERENCE_GITHUB_TOKEN" ;;
        *) exit 1 ;;
      esac
      """
    try Data(script.utf8).write(to: askpass, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
    let environment = [
      "HOME": home.path,
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_COUNT": "0",
      "GIT_NO_REPLACE_OBJECTS": "1",
      "GIT_TERMINAL_PROMPT": "0",
    ]
    self.git = git ?? SwiftSubprocessRunner(
      executablePath: "/usr/bin/git", environmentForTesting: environment
    )
    self.pushGit = pushGit ?? SwiftSubprocessRunner(
      executablePath: "/usr/bin/git",
      environmentForTesting: environment.merging([
        "CLAW_CONFERENCE_GITHUB_TOKEN": token,
        "GIT_ASKPASS": askpass.path,
      ]) { _, replacement in replacement }
    )
  }

  func publish(_ request: ConferencePublicationRequest) async throws -> ConferencePublication {
    let repository = try repositoryIdentity(request.repositoryURL)
    let branch = "conference/\(request.submissionID.uuidString.lowercased())"
    // Recover a lost POST response before touching the local workspace or pushing again.
    if let existing = try await existingPullRequest(repository: repository, branch: branch) {
      return try validatedPublication(existing, repository: repository, branch: branch, request: request)
    }
    let workspace = try validatedWorkspace(request.workspacePath)
    try await validateCommit(request, workspace: workspace)
    let transfer = home.appendingPathComponent("transfer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: transfer) }
    try await gitSuccess(["init", "--bare", "--template=", transfer.path])
    try await gitSuccess([
      "--git-dir", transfer.path, "fetch", "--no-tags", "--", workspace, request.commit,
    ])
    try await gitSuccess([
      "--git-dir", transfer.path, "merge-base", "--is-ancestor",
      request.startingCommit, request.commit,
    ])
    // Only this clean supervisor-owned repository is ever opened with publication credentials.
    let pushed = await pushGit.run(command([
      "--git-dir", transfer.path, "push", "--no-verify", "--porcelain", "--",
      "https://github.com/\(repository).git", "\(request.commit):refs/heads/\(branch)",
    ], authenticated: true))
    if Task.isCancelled || pushed.termination == .cancelled {
      throw CancellationError()
    }
    guard pushed.termination == .exited(0) else {
      throw ConferencePublicationError.pushFailed
    }
    let created = try await createPullRequest(request: request, repository: repository, branch: branch)
    return try validatedPublication(created, repository: repository, branch: branch, request: request)
  }
}

// MARK: - Local Git boundary

private extension ConferenceGitHubPublisher {
  func repositoryIdentity(_ raw: String) throws -> String {
    guard let url = URLComponents(string: raw),
      url.scheme == "https", url.host == "github.com",
      url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil, url.percentEncodedPath == url.path
    else {
      throw ConferencePublicationError.invalidRepository
    }
    let parts = url.path.split(separator: "/")
    guard parts.count == 2 else {
      throw ConferencePublicationError.invalidRepository
    }
    let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : String(parts[1])
    guard validRepositoryPart(String(parts[0])), validRepositoryPart(name) else {
      throw ConferencePublicationError.invalidRepository
    }
    return "\(parts[0])/\(name)"
  }

  func validRepositoryPart(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.hasPrefix("-")
      && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || $0 == 45 || $0 == 46 || $0 == 95
      }
  }

  func validatedWorkspace(_ raw: String) throws -> String {
    let workspace = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
    let jobs = stateRoot.appendingPathComponent("coder/jobs", isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard workspace.path.hasPrefix(jobs.path + "/") else {
      throw ConferencePublicationError.invalidWorkspace
    }
    return workspace.path
  }

  func validateCommit(_ request: ConferencePublicationRequest, workspace: String) async throws {
    guard validCommit(request.startingCommit), validCommit(request.commit),
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

  func gitSuccess(_ arguments: [String]) async throws {
    _ = try await gitOutput(arguments)
  }

  func gitOutput(_ arguments: [String]) async throws -> String {
    let result = await git.run(command(arguments))
    if Task.isCancelled || result.termination == .cancelled {
      throw CancellationError()
    }
    guard result.termination == .exited(0), !result.stdout.truncated,
      let output = String(data: result.stdout.bytes, encoding: .utf8)
    else {
      throw ConferencePublicationError.invalidCommit
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func command(_ arguments: [String], authenticated: Bool = false) -> SubprocessCommand {
    SubprocessCommand(
      arguments: [
        "--no-pager", "-c", "credential.helper=", "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false", "-c", "maintenance.auto=false", "-c", "gc.auto=0",
      ] + arguments,
      timeout: .seconds(60),
      captureLimit: 64 * 1024,
      teardownGracePeriod: .seconds(2),
      environmentKeysToRemove: ["GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "SSH_AUTH_SOCK"]
        + (authenticated ? [] : ["CLAW_CONFERENCE_GITHUB_TOKEN", "GIT_ASKPASS"])
    )
  }
}

// MARK: - GitHub boundary

private extension ConferenceGitHubPublisher {
  struct PullRequest: Decodable {
    struct User: Decodable { let login: String }
    struct Repository: Decodable {
      let fullName: String
      enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    struct Ref: Decodable {
      let ref: String
      let sha: String
      let repo: Repository?
    }
    let number: Int
    let htmlURL: String
    let user: User
    let head: Ref
    let base: Ref
    let state: String
    let draft: Bool
    let mergedAt: String?

    enum CodingKeys: String, CodingKey {
      case number, user, head, base, state, draft
      case htmlURL = "html_url"
      case mergedAt = "merged_at"
    }
  }

  struct CreatePullRequest: Encodable {
    let title: String
    let head: String
    let base: String
    let body: String
    let draft: Bool
  }

  func existingPullRequest(repository: String, branch: String) async throws -> PullRequest? {
    let owner = repository.split(separator: "/")[0]
    var components = URLComponents(string: "https://api.github.com/repos/\(repository)/pulls")
    components?.queryItems = [
      URLQueryItem(name: "state", value: "all"),
      URLQueryItem(name: "head", value: "\(owner):\(branch)"),
    ]
    guard let url = components?.url?.absoluteString else {
      throw ConferencePublicationError.invalidRepository
    }
    let result = try await execute(method: .get, url: url, body: nil)
    try checkStatus(result.statusCode)
    guard let pulls = try? JSONDecoder().decode([PullRequest].self, from: result.body) else {
      throw ConferencePublicationError.apiFailed
    }
    return pulls.first
  }

  func createPullRequest(
    request: ConferencePublicationRequest,
    repository: String,
    branch: String
  ) async throws -> PullRequest {
    let item = request.proposal.caseSnapshot
    let body = CreatePullRequest(
      title: "Challenge \(item.id): submission \(request.submissionID.uuidString.lowercased())",
      head: branch,
      base: request.baseBranch,
      body: """
        <!-- conference-submission:\(request.submissionID.uuidString.lowercased()) -->
        ## Case: \(item.id)
        \(escaped(item.title))

        <details><summary>Published case</summary><pre>\(escaped(item.prompt))</pre></details>

        ## Participant proposal (verbatim)
        <pre>\(escaped(request.proposal.answer))</pre>

        Submission ID: `\(request.submissionID.uuidString.lowercased())`.
        The organizer retains its participant attribution; private Telegram IDs are not published.
        Baseline: `\(request.startingCommit)`.

        ## Checks reported by Coder (not independently verified)
        <pre>\(escaped(request.reportedChecks.prefix(10).map { String($0.prefix(1_000)) }.joined(separator: "\n")))</pre>

        AI-generated prototype of the participant's idea. Human review is required; no automatic score or merge.
        """,
      draft: true
    )
    let result = try await execute(
      method: .post,
      url: "https://api.github.com/repos/\(repository)/pulls",
      body: JSONEncoder().encode(body)
    )
    if result.statusCode == 422,
      let existing = try await existingPullRequest(repository: repository, branch: branch)
    {
      return existing
    }
    try checkStatus(result.statusCode)
    guard result.statusCode == 201,
      let pull = try? JSONDecoder().decode(PullRequest.self, from: result.body)
    else {
      throw ConferencePublicationError.apiFailed
    }
    return pull
  }

  func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  func checkStatus(_ status: Int) throws {
    guard HTTPResponseBodyPolicy.isSuccess(status) else {
      if status == 408 || status == 429 || status == 403 || status >= 500 {
        throw ConferencePublicationError.apiFailed
      }
      throw ConferencePublicationError.invalidPublication
    }
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
    repository: String,
    branch: String,
    request: ConferencePublicationRequest
  ) throws -> ConferencePublication {
    guard pull.head.ref == branch, pull.head.sha == request.commit,
      pull.base.ref == request.baseBranch,
      pull.base.sha.caseInsensitiveCompare(request.startingCommit) == .orderedSame,
      pull.head.repo?.fullName.lowercased() == repository.lowercased(),
      pull.base.repo?.fullName.lowercased() == repository.lowercased(),
      pull.state == "open", pull.draft, pull.mergedAt == nil,
      pull.number > 0,
      pull.htmlURL == "https://github.com/\(repository)/pull/\(pull.number)"
    else {
      throw ConferencePublicationError.invalidPublication
    }
    guard pull.user.login.caseInsensitiveCompare(expectedActor) == .orderedSame else {
      throw ConferencePublicationError.actorMismatch(expected: expectedActor, actual: pull.user.login)
    }
    return ConferencePublication(
      pullRequestURL: pull.htmlURL, branch: branch, commit: request.commit, actor: pull.user.login
    )
  }
}
