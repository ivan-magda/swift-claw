import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import clawd

@Suite struct ConferenceSecurityBoundaryTests {
  @Test func coderUsesDedicatedHomeAndDropsAllGitHubPublicationCredentials() async throws {
    // given
    let root = try makeTemporaryRoot(prefix: "conference-coder-boundary")
    defer { try? FileManager.default.removeItem(at: root) }
    let coderHome = root.appendingPathComponent("coder-home", isDirectory: true)
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
      AppConfig.EnvKey.coderEnabled: "true",
      AppConfig.EnvKey.coderConfigHome: coderHome.path,
    ])
    let http = ScriptedHTTPExecutor([])
    let builder = try CompositionAcceptance.makeBuilder(http: http, config: config)

    // when
    let isolated = try builder.conferenceCoderEnvironment(environment: [
      "HOME": "/Users/ivan",
      "PATH": "/usr/bin:/bin",
      "GH_TOKEN": "conference-bot-token",
      "GITHUB_TOKEN": "personal-github-token",
      "GH_CONFIG_DIR": "/Users/ivan/.config/gh",
      "SSH_AUTH_SOCK": "/tmp/personal-ssh-agent",
      "GIT_ASKPASS": "/Users/ivan/bin/askpass",
    ])

    // then
    #expect(isolated["HOME"] == root.appendingPathComponent("conference-home").path)
    #expect(isolated["CODEX_HOME"] == coderHome.path)
    #expect(isolated["GH_TOKEN"] == nil)
    #expect(isolated["GITHUB_TOKEN"] == nil)
    #expect(isolated["GH_CONFIG_DIR"] == nil)
    #expect(isolated["SSH_AUTH_SOCK"] == nil)
    #expect(isolated["GIT_ASKPASS"] == nil)
  }

  @Test func coderRejectsConfigHomeSymlinkEscapingStateRoot() async throws {
    // given
    let root = try makeTemporaryRoot(prefix: "conference-coder-symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let externalHome = try makeTemporaryRoot(prefix: "conference-external-coder-home")
    defer { try? FileManager.default.removeItem(at: externalHome) }
    let coderHome = root.appendingPathComponent("coder-home", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: coderHome, withDestinationURL: externalHome)
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
      AppConfig.EnvKey.coderEnabled: "true",
      AppConfig.EnvKey.coderConfigHome: coderHome.path,
    ])
    let builder = try CompositionAcceptance.makeBuilder(
      http: ScriptedHTTPExecutor([]),
      config: config
    )

    // when / then
    #expect(throws: ConferenceConfigError.isolatedCoderHomeRequired) {
      _ = try builder.conferenceCoderEnvironment(environment: [:])
    }
  }

  @Test func startupRejectsGitHubCredentialForWrongActor() async throws {
    // given
    let root = try makeTemporaryRoot(prefix: "conference-github-actor")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
    ])
    let http = ScriptedHTTPExecutor([
      .ok(
        HTTPResult(
          statusCode: 200,
          headers: [:],
          body: Data(#"{"login":"ivan-magda"}"#.utf8)
        )
      )
    ])
    let builder = try CompositionAcceptance.makeBuilder(http: http, config: config)
    let conference = ConferenceConfig(
      enabled: true,
      activeCase: nil,
      expectedGitHubActor: "crew18-bot"
    )

    // when
    do {
      try await builder.verifyConferenceGitHubActor(
        config: conference,
        environment: ["GH_TOKEN": "dedicated-token"]
      )
      Issue.record("Conference startup accepted a GitHub credential for the wrong actor")
    } catch ConferenceConfigError.githubActorMismatch(let expected, let actual) {
      #expect(expected == "crew18-bot")
      #expect(actual == "ivan-magda")
    } catch {
      Issue.record("Unexpected GitHub actor verification error: \(error)")
    }

    // then
    let recorded = try #require(await http.recorded.first)
    #expect(recorded.url == "https://api.github.com/user")
    #expect(recorded.headers["Authorization"] == "Bearer dedicated-token")
    #expect(recorded.headers["User-Agent"] == conference.expectedGitHubActor)
  }
}
