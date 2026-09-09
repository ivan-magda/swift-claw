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

  func prepareConference(
    coder: CoderComposition,
    coordination: TurnCoordination
  ) throws -> ConferenceComposition {
    let conference = try ConferenceConfig.load(
      environment: ProcessInfo.processInfo.environment
    )
    guard conference.enabled else {
      return .disabled
    }
    guard config.coder.enabled, let coderService = coder.service else {
      throw ConferenceConfigError.coderRequired
    }
    guard let activeCase = conference.activeCase else {
      throw ConferenceConfigError.invalidCaseFile
    }

    let signal = coordination.outboxSignal
    let service = ConferenceWorkflowService(
      config: conference,
      store: stores.conference,
      coder: coderService,
      coderJobs: stores.coderJobs,
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
      conference.expectedGitHubActor ?? "missing",
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
