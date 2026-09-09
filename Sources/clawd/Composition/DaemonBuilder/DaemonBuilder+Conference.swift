import ClawCore
import ClawGateway
import ClawTools
import Foundation

extension DaemonBuilder {
  struct ConferenceComposition: Sendable {
    let config: ConferenceConfig
    let service: ConferenceWorkflowService?
    let tools: [any Tool]

    var enabled: Bool { config.enabled }

    static let disabled = ConferenceComposition(
      config: .disabled,
      service: nil,
      tools: []
    )
  }

  func loadConferenceConfig() throws -> ConferenceConfig {
    try ConferenceConfig.load(environment: ProcessInfo.processInfo.environment)
  }

  func verifyConferenceGitHubActor(
    config conference: ConferenceConfig,
    environment: [String: String]
  ) async throws {
    guard conference.enabled else {
      return
    }
    guard let expected = conference.expectedGitHubActor else {
      throw ConferenceConfigError.githubActorVerificationFailed
    }
    guard let token = environment["GH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else {
      throw ConferenceConfigError.githubTokenRequired
    }

    let result: HTTPResult
    do {
      result = try await toolExecutor.get(
        url: "https://api.github.com/user",
        headers: [
          "Accept": "application/vnd.github+json",
          "Authorization": "Bearer \(token)",
          "X-GitHub-Api-Version": "2022-11-28",
        ],
        timeoutSeconds: 10,
        maxBodyBytes: 16 * 1024
      )
    } catch {
      throw ConferenceConfigError.githubActorVerificationFailed
    }
    guard HTTPResponseBodyPolicy.isSuccess(result.statusCode) else {
      throw ConferenceConfigError.githubActorVerificationFailed
    }

    struct Actor: Decodable { let login: String }
    guard let actor = try? JSONDecoder().decode(Actor.self, from: result.body) else {
      throw ConferenceConfigError.githubActorVerificationFailed
    }
    guard actor.login.caseInsensitiveCompare(expected) == .orderedSame else {
      throw ConferenceConfigError.githubActorMismatch(expected: expected, actual: actor.login)
    }
  }

  func prepareConference(
    config conference: ConferenceConfig,
    coder: CoderComposition,
    coordination: TurnCoordination,
    environment: [String: String]
  ) async throws -> ConferenceComposition {
    guard conference.enabled else {
      return .disabled
    }
    guard config.coder.enabled, let coderService = coder.service else {
      throw ConferenceConfigError.coderRequired
    }
    guard let activeCase = conference.activeCase else {
      throw ConferenceConfigError.invalidCaseFile
    }
    guard let expectedActor = conference.expectedGitHubActor,
      let token = environment["GH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else {
      throw ConferenceConfigError.githubTokenRequired
    }

    let sourcePath = try await ConferenceRepositorySource(stateRoot: config.stateRoot)
      .prepare(activeCase)
    let publisher = try ConferenceGitHubPublisher(
      stateRoot: config.stateRoot,
      token: token,
      expectedActor: expectedActor,
      http: toolExecutor
    )
    let signal = coordination.outboxSignal
    let service = ConferenceWorkflowService(
      config: conference,
      sourcePath: sourcePath,
      store: stores.conference,
      coder: coderService,
      coderJobs: stores.coderJobs,
      publisher: publisher,
      outbox: stores.outbox,
      notifyOutbox: { signal.poke() },
      logger: logger,
      now: now
    )
    let identity = PolicyFingerprint.hash(parts: [
      "conference-coding-challenge-v1",
      activeCase.id,
      activeCase.repositoryURL,
      activeCase.baselineRef,
      activeCase.baseBranch,
      expectedActor,
    ])
    let redactor = SecretRedactor(secretValues: redactionValues)
    let tools: [any Tool] = [
      ConferenceCurrentTool(service: service),
      ConferenceSubmitTool(
        service: service,
        invocationIdentity: identity,
        redactor: redactor
      ),
      ConferenceStatusTool(service: service),
    ]
    return ConferenceComposition(config: conference, service: service, tools: tools)
  }
}
