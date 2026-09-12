import Foundation
import Testing

@testable import ClawCore

@Suite struct ConferenceConfigTests {
  @Test func disabledProfileRequiresNoConferenceSettings() throws {
    let config = try ConferenceConfig.load(environment: [:])

    #expect(config == .disabled)
  }

  @Test func enabledProfileRequiresExplicitStateRoot() throws {
    #expect(throws: ConferenceConfigError.explicitStateRootRequired) {
      _ = try ConferenceConfig.load(environment: [
        ConferenceConfig.EnvKey.enabled: "true"
      ])
    }
  }

  @Test func enabledProfileRequiresExpectedGitHubActor() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }

    #expect(
      throws: ConferenceConfigError.invalidSetting(
        ConferenceConfig.EnvKey.expectedGitHubActor
      )
    ) {
      _ = try ConferenceConfig.load(environment: fixture.environment(actor: nil))
    }
  }

  @Test func validProfileLoadsTrustedCaseAndActor() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }

    let config = try ConferenceConfig.load(
      environment: fixture.environment(actor: "crew18-bot")
    )

    #expect(config.enabled)
    #expect(config.activeCase == fixture.caseItem)
    #expect(config.expectedGitHubActor == "crew18-bot")
  }
}

private extension ConferenceConfigTests {
  struct Fixture {
    let root: URL
    let caseFile: URL
    let caseItem: ConferenceCase

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("conference-config-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      caseFile = root.appendingPathComponent("case.json")
      caseItem = ConferenceCase(
        id: "day-1",
        title: "Accessibility regression",
        prompt: "Propose a fix for the accessibility regression.",
        repositoryURL: "https://github.com/wowlocal/crew18-sim",
        baselineRef: String(repeating: "a", count: 40),
        baseBranch: "challenge/day-1"
      )
      try JSONEncoder().encode(caseItem).write(to: caseFile, options: .atomic)
    }

    func environment(actor: String?) -> [String: String] {
      var environment = [
        ConferenceConfig.EnvKey.enabled: "true",
        AppConfig.EnvKey.stateRoot: root.path,
        ConferenceConfig.EnvKey.caseFile: caseFile.path,
      ]
      if let actor {
        environment[ConferenceConfig.EnvKey.expectedGitHubActor] = actor
      }
      return environment
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
