import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import clawd

@Suite struct ConferencePolicyCompositionTests {
  @Test func resolvedCoderPolicyBindsConferenceIdentityAndPreparedSubmission() async throws {
    // given
    let fixture = try CoderCompositionFixture()
    defer { fixture.cleanup() }
    let caseID = "policy-case"
    let repository = "https://github.com/example/project"
    let source = fixture.root.appendingPathComponent("conference-source/\(caseID)")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try await conferenceGit(["init", source.path])
    _ = try await conferenceGit([
      "-C", source.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
      "commit", "--allow-empty", "-m", "Baseline",
    ])
    let baseline = try await conferenceGit(["-C", source.path, "rev-parse", "HEAD"])
    _ = try await conferenceGit(["-C", source.path, "remote", "add", "origin", repository])
    let config = ConferenceConfig(
      enabled: true,
      activeCase: ConferenceCase(
        id: caseID,
        title: "Concurrency",
        prompt: "Propose a concurrency-safe implementation.",
        repositoryURL: repository,
        baselineRef: baseline,
        baseBranch: "challenge/policy"
      ),
      expectedGitHubActor: "conference-bot"
    )

    // when
    let original = try await composeSubmission(
      fixture: fixture,
      config: config,
      searchPath: "/usr/bin:/bin"
    )
    let changed = try await composeSubmission(
      fixture: fixture,
      config: config,
      searchPath: "/opt/conference/bin:/usr/bin:/bin"
    )

    // then
    #expect(original.identity != changed.identity)
    #expect(original.preparedPolicy == original.coderPolicy)
    #expect(changed.preparedPolicy == changed.coderPolicy)
  }
}

// MARK: - Composition

private extension ConferencePolicyCompositionTests {
  func composeSubmission(
    fixture: CoderCompositionFixture,
    config: ConferenceConfig,
    searchPath: String
  ) async throws -> (identity: String, preparedPolicy: String?, coderPolicy: String) {
    var builder = fixture.builder
    let resolveCoder = builder.resolveCoder
    builder.resolveCoder = { config in
      var setup = try await resolveCoder(config)
      setup.searchPath = searchPath
      return setup
    }
    let coordination = DaemonBuilder.TurnCoordination()
    let coder = await builder.prepareCoder(coordination: coordination)
    let conference = try await builder.prepareConference(
      config: config,
      coder: coder,
      coordination: coordination,
      environment: ["GH_TOKEN": "fixture-bot-token"],
      judgeRoute: makeSingleRouteRoster(provider: SequenceProvider([]), wireModel: "fixture")
        .primary
    )
    let submit = try #require(
      conference.tools.first {
        $0.definition.name == ConferenceToolNames.submit
      }
    )
    let identity = try #require(submit.definition.invocationIdentity)
    let resolution = await submit.prepareAction(
      arguments: .object(["answer": .string("Protect the shared state with an actor.")])
    )
    let action: PreparedToolAction? =
      if case .prepared(let action) = resolution { action } else { nil }
    let canonical = try #require(action).canonicalArgsJSON
    let prepared = try JSONDecoder().decode(
      PreparedConferenceSubmission.self,
      from: Data(canonical.utf8)
    )
    return (identity, prepared.executionPolicyID, coder.executionPolicyID)
  }
}
