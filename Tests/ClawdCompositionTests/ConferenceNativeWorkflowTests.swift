import ClawCore
import ClawData
import ClawGateway
import ClawSubprocess
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import clawd

@Suite struct ConferenceNativeWorkflowTests {
  @Test func independentParticipantsPublishOnceThroughNativeCoderAndGit() async throws {
    // given — real composition, Coder, Git, stores and publisher; external APIs are local.
    let fixture = try await ConferenceNativeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try await fixture.builder.prepareConferenceCoder(
      coordination: TurnCoordination(),
      environment: fixture.environment
    )
    let coder = try #require(composition.service)
    try await coder.start()
    let source = ConferenceRepositorySource(stateRoot: fixture.root)
    let push = ConferenceLocalPush(remote: fixture.remote)
    let github = ConferenceLocalGitHub(remote: fixture.remote)
    let publisher = try ConferenceGitHubPublisher(
      stateRoot: fixture.root,
      token: "fixture-bot-token",
      expectedActor: "crew18-bot",
      http: github,
      pushGit: push
    )
    let judge = ConferenceSubmissionJudge(provider: ConferencePassingJudge(), model: "fixture")
    let service = ConferenceWorkflowService(
      config: ConferenceConfig(
        enabled: true,
        activeCase: fixture.item,
        expectedGitHubActor: "crew18-bot"
      ),
      prepareSource: { try await source.prepare($0) },
      validateSubmission: { try await judge.check($0) },
      store: fixture.builder.stores.conference,
      coder: coder,
      coderJobs: fixture.builder.stores.coderJobs,
      publisher: publisher,
      outbox: fixture.builder.stores.outbox,
      notifyOutbox: {},
      logger: Logger(label: "conference-native")
    )
    let runner = Task { try await service.run() }
    do {
      // when — both participants use the same immutable case without sharing a working copy.
      let first = try await fixture.submit(
        answer: "Restore labels and add a VoiceOver regression test.",
        userID: 101,
        service: service
      )
      let second = try await fixture.submit(
        answer: "Keep component accessibility state in an actor.",
        userID: 202,
        service: service
      )
      let finished = try await pollUntilTrue {
        try [first, second].allSatisfy { submission in
          guard let row = try fixture.builder.stores.conference.submission(id: submission.id) else {
            return false
          }
          return row.state.isTerminal && row.notificationEnqueued
        }
      }
      runner.cancel()
      _ = await runner.result
      try await coder.shutdown()
      try #require(finished)

      // then — lost POST response must reuse the existing PR, not repeat Coder or publication.
      try await fixture.verify([first, second], github: github, push: push)
    } catch {
      runner.cancel()
      _ = await runner.result
      try? await coder.shutdown()
      throw error
    }
  }
}

private struct ConferenceNativeFixture {
  let root: URL
  let source: URL
  let remote: URL
  let item: ConferenceCase
  let queue: DatabaseQueue
  let builder: DaemonBuilder
  let environment: [String: String]

  init() async throws {
    root = try makeTemporaryRoot(prefix: "conference-native")
      .resolvingSymlinksInPath()
    source = root.appendingPathComponent("conference-source/day-1")
    remote = root.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try await conferenceGit(["init", "--initial-branch=challenge/day-1", source.path])
    try Data("baseline\n".utf8).write(to: source.appendingPathComponent("feature.txt"))
    _ = try await conferenceGit(["-C", source.path, "add", "feature.txt"])
    _ = try await conferenceGit([
      "-C", source.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
      "commit", "-m", "Baseline",
    ])
    let baseline = try await conferenceGit(["-C", source.path, "rev-parse", "HEAD"])
    _ = try await conferenceGit([
      "-C", source.path, "remote", "add", "origin", "https://github.com/wowlocal/crew18-sim",
    ])
    _ = try await conferenceGit(["init", "--bare", remote.path])
    _ = try await conferenceGit([
      "-C", source.path, "push", remote.path, "HEAD:refs/heads/challenge/day-1",
    ])
    item = ConferenceCase(
      id: "day-1",
      title: "Accessibility",
      prompt: "A new component version has accessibility regressions. Propose a solution.",
      repositoryURL: "https://github.com/wowlocal/crew18-sim",
      baselineRef: baseline,
      baseBranch: "challenge/day-1"
    )
    let executable = root.appendingPathComponent("codex")
    try Data(Self.codexScript.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    environment = [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
      AppConfig.EnvKey.coderEnabled: "true",
      "CLAW_CODER_CONFIG_HOME": root.appendingPathComponent("codex-home").path,
      "PATH": "\(root.path):/usr/bin:/bin",
      "GH_TOKEN": "fixture-bot-token",
    ]
    let config = try AppConfig.load(environment: environment)
    builder = try CompositionAcceptance.makeBuilder(http: ScriptedHTTPExecutor([]), config: config)
    queue = try DatabaseQueue(path: root.appendingPathComponent(StateFile.database).path)
  }

  func submit(
    answer: String,
    userID: Int64,
    service: ConferenceWorkflowService
  ) async throws -> ConferenceSubmission {
    let prepared = try await service.prepareSubmission(answer: answer)
    let origin = try ConferenceApprovedOriginFixture.make(
      queue: queue,
      prepared: prepared,
      userID: userID,
      updateID: userID
    )
    let submission = try await service.submit(prepared, context: origin.executionContext)
    let replay = try await service.submit(prepared, context: origin.executionContext)
    #expect(replay.id == submission.id)
    return submission
  }

  func verify(
    _ submissions: [ConferenceSubmission],
    github: ConferenceLocalGitHub,
    push: ConferenceLocalPush
  ) async throws {
    var workspaces: Set<String> = []
    var commits: Set<String> = []
    for submitted in submissions {
      let row = try #require(try builder.stores.conference.submission(id: submitted.id))
      #expect(row.state == .completed, "\(row.failureReason ?? "no diagnostic")")
      let jobID = try #require(row.coderJobID)
      let job = try #require(try builder.stores.coderJobs.job(id: jobID))
      let result = try #require(job.result)
      #expect(result.baselineObserved)
      #expect(result.startingCommit == item.baselineRef)
      workspaces.insert(try #require(result.workspacePath))
      commits.insert(try #require(result.commit))
      let branch = try #require(row.branch)
      let remoteHead = try await conferenceGit(["--git-dir", remote.path, "rev-parse", branch])
      #expect(remoteHead == result.commit)
      let notices = try builder.stores.outbox.pendingOutbound().filter {
        $0.payload.contains(row.id.uuidString.lowercased())
      }
      #expect(notices.count == 1)
      #expect(notices.first?.chatId == submitted.participantUserID)
      #expect(await github.bodies[branch]?.contains(submitted.answer) == true)
    }
    #expect(workspaces.count == 2)
    #expect(commits.count == 2)
    #expect(await github.created == 2)
    #expect(await push.count == 2)
    #expect(try builder.stores.outbox.pendingOutbound().count == 4)
    let unchanged = try await conferenceGit(["-C", source.path, "rev-parse", "HEAD"])
    #expect(unchanged == item.baselineRef)
    let base = try await conferenceGit(["--git-dir", remote.path, "rev-parse", item.baseBranch])
    #expect(base == item.baselineRef)
  }
}

private extension ConferenceNativeFixture {
  static let codexScript = #"""
    #!/bin/sh
    set -eu
    if [ "$1" = '--version' ]; then printf 'codex-cli 0.153.4\n'; exit 0; fi
    if [ "$1" = 'login' ]; then exit 0; fi
    if [ "${2-}" = '--help' ]; then
      printf '%s\n' '--json --approve-for-me --config --skip-git-repo-check --ephemeral'
      printf '%s\n' '--color --cd --output-schema --output-last-message --profile'
      exit 0
    fi
    test -z "${GH_TOKEN-}"
    test -z "${GITHUB_TOKEN-}"
    test -z "${SSH_AUTH_SOCK-}"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '-o' ]; then shift; report=$1; fi
      shift
    done
    cat >/dev/null
    printf '%s\n' "$(basename "$(dirname "$PWD")")" >> feature.txt
    git add feature.txt
    git -c user.name='Conference Coder' -c user.email=fixture@example.test commit -qm Implementation
    cat > "$report" <<'JSON'
    {"status":"succeeded","summary":"Fixture implementation","starting_commit":null,
    "base_branch":null,"changed_files":null,"branch":null,"commit":null,"pr_url":null,
    "checks":["Fixture only; no iOS build performed"],"error":null}
    JSON
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":10}}'
    """#
}

private struct ConferencePassingJudge: LLMProvider {
  func complete(request: ChatRequest) async throws -> ChatResponse {
    #expect(request.tools.isEmpty)
    return ChatResponse(content: "SAFE", finishReason: "stop", usage: .zero, costFromProvider: nil)
  }
}

private func conferenceGit(_ arguments: [String]) async throws -> String {
  let runner = SwiftSubprocessRunner(
    executablePath: "/usr/bin/git",
    environmentForTesting: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
  )
  let result = await runner.run(
    SubprocessCommand(
      arguments: arguments,
      timeout: .seconds(30),
      captureLimit: 64 * 1024,
      teardownGracePeriod: .seconds(1)
    )
  )
  guard result.termination == .exited(0), !result.stdout.truncated else {
    throw StoreError.unexpected(
      "Fixture Git failed: \(String(decoding: result.stderr.bytes, as: UTF8.self))"
    )
  }
  return String(decoding: result.stdout.bytes, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private actor ConferenceLocalPush: SubprocessRunning {
  let remote: URL
  private(set) var count = 0

  init(remote: URL) { self.remote = remote }

  func run(_ command: SubprocessCommand) async -> SubprocessResult {
    count += 1
    #expect(command.arguments.contains("push"))
    #expect(command.arguments.contains("https://github.com/wowlocal/crew18-sim.git"))
    #expect(command.arguments.contains { $0.contains("conference-publisher/transfer-") })
    let arguments = command.arguments.map {
      $0 == "https://github.com/wowlocal/crew18-sim.git" ? remote.path : $0
    }
    return await SwiftSubprocessRunner(executablePath: "/usr/bin/git").run(
      SubprocessCommand(
        arguments: arguments,
        timeout: command.timeout,
        captureLimit: command.captureLimit,
        teardownGracePeriod: command.teardownGracePeriod
      )
    )
  }
}

private actor ConferenceLocalGitHub: HTTPExecuting {
  let remote: URL
  private var pulls: [String: Data] = [:]
  private(set) var bodies: [String: String] = [:]
  private(set) var created = 0
  private var loseFirstResponse = true

  init(remote: URL) { self.remote = remote }

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    #expect(request.headers["Authorization"] == "Bearer fixture-bot-token")
    let url = try #require(URLComponents(string: request.url))
    #expect(url.path == "/repos/wowlocal/crew18-sim/pulls")
    if request.method == .get {
      #expect(url.queryItems?.contains(URLQueryItem(name: "state", value: "all")) == true)
      let head = try #require(url.queryItems?.first { $0.name == "head" }?.value)
      let branch = String(head.dropFirst("wowlocal:".count))
      let body =
        pulls[branch].map { Data("[\(String(decoding: $0, as: UTF8.self))]".utf8) }
        ?? Data("[]".utf8)
      return HTTPResult(statusCode: 200, headers: [:], body: body)
    }
    #expect(request.method == .post)
    let input = try JSONDecoder().decode(CreateRequest.self, from: #require(request.body))
    #expect(input.draft)
    #expect(pulls[input.head] == nil)
    let headSHA = try await conferenceGit(["--git-dir", remote.path, "rev-parse", input.head])
    let baseSHA = try await conferenceGit(["--git-dir", remote.path, "rev-parse", input.base])
    created += 1
    let repository = ["full_name": "wowlocal/crew18-sim"]
    let object: [String: Any] = [
      "number": created,
      "html_url": "https://github.com/wowlocal/crew18-sim/pull/\(created)",
      "user": ["login": "crew18-bot"],
      "head": ["ref": input.head, "sha": headSHA, "repo": repository],
      "base": ["ref": input.base, "sha": baseSHA, "repo": repository],
      "state": "open", "draft": true, "merged_at": NSNull(),
    ]
    let body = try JSONSerialization.data(withJSONObject: object)
    pulls[input.head] = body
    bodies[input.head] = input.body
    if loseFirstResponse {
      loseFirstResponse = false
      throw HTTPTransportFailure(
        disposition: .mayHaveBeenSent,
        safeMessage: "Fixture response lost"
      )
    }
    return HTTPResult(statusCode: 201, headers: [:], body: body)
  }

  struct CreateRequest: Decodable {
    let head: String
    let base: String
    let body: String
    let draft: Bool
  }
}
