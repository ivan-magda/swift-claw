import ClawCoder
import ClawCore
import ClawData
import ClawGateway
import ClawTestSupport
import Foundation
import GRDB

@testable import clawd

struct CoderCompositionFixture {
  let root: URL
  let queue: DatabaseQueue
  let builder: DaemonBuilder
  let backend: ScriptedCoderBackend
  let http: ScriptedHTTPExecutor

  init(
    enabled: Bool = true,
    limit: Int = CoderConfig.Defaults.maxConcurrentJobs,
    holdCleanup: Bool = false,
    unresolvedCleanup: Bool = false,
    authentication: CodexAuthenticationStatus = .authenticated
  ) throws {
    root = try makeTemporaryRoot(prefix: "coder-composition")
    var environment = [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
      AppConfig.EnvKey.coderEnabled: enabled ? "true" : "false",
      AppConfig.EnvKey.coderMaxConcurrentJobs: String(limit),
    ]
    if authentication == .profileUnverified {
      environment[AppConfig.EnvKey.coderProfile] = "coding"
    }
    let config = try AppConfig.load(environment: environment)
    http = ScriptedHTTPExecutor([])
    backend = ScriptedCoderBackend(invocations: [
      .init(result: Self.result, holdCleanup: holdCleanup, unresolvedCleanup: unresolvedCleanup)
    ])
    var builder = try CompositionAcceptance.makeBuilder(http: http, config: config)
    let backend = backend
    builder.resolveCoder = { config in
      CoderBackendSetup(
        backend: backend,
        executable: "/test/codex",
        profile: config.profile,
        configHome: "/test/config",
        credentialSources: [:],
        version: "scripted",
        authentication: authentication
      )
    }
    self.builder = builder
    queue = try DatabaseQueue(path: root.appendingPathComponent(StateFile.database).path)
  }

  func approvedContext(_ prepared: CoderPreparedRequest) throws -> ToolExecutionContext {
    let origin = try CoderApprovedOriginFixture.make(
      queue: queue,
      updateID: 1,
      prepared: prepared,
      now: Date()
    )
    return ToolExecutionContext(
      runId: origin.runID,
      sessionId: origin.sessionID,
      chatId: origin.chatID,
      requesterUserId: origin.requesterUserID,
      origin: .interactive,
      mode: .direct,
      toolCallId: origin.toolCallID,
      approvalId: origin.approvalID
    )
  }

  func cleanup() {
    backend.releaseAll()
    try? FileManager.default.removeItem(at: root)
  }

  static let request = CoderRequest(
    source: .githubRepository(url: "https://github.com/example/project"),
    task: "Fix retry",
    workspace: .separate,
    startRef: nil,
    deliverable: .localChanges,
    baseBranch: nil,
    instructions: nil,
    publishExistingChanges: false
  )

  static let result = CoderResult(
    state: .succeeded,
    summary: "Completed",
    workspacePath: nil,
    startingCommit: nil,
    baselineObserved: false,
    changedFiles: nil,
    branch: nil,
    commit: nil,
    publication: .absent,
    reportedChecks: [],
    reportedUsage: nil,
    commitAuthor: nil,
    githubActor: nil,
    failure: nil
  )
}
