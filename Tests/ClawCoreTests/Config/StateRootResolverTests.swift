import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore

/// The mode the resolver is expected to leave on a directory it creates. Read back through
/// `FileManager` rather than restated as a literal at each call site.
private func posixPermissions(of url: URL) throws -> Int? {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue
}

@Suite struct StateRootResolverTests {
  // MARK: - Creation

  @Test func anExplicitPathIsCreatedAtTheOwnerOnlyMode() throws {
    // given
    let parent = try makeTemporaryRoot(prefix: "state-root-explicit")
    defer { try? FileManager.default.removeItem(at: parent) }
    let named = parent.appendingPathComponent("root", isDirectory: true)

    // when
    let resolved = try StateRootResolver.createStateRoot(for: named.path)

    // then
    #expect(resolved.standardizedFileURL == named.standardizedFileURL)
    #expect(try posixPermissions(of: resolved) == 0o700)
  }

  @Test func anExistingStateRootIsAcceptedRatherThanRecreated() throws {
    // given
    let existing = try makeTemporaryRoot(prefix: "state-root-existing")
    defer { try? FileManager.default.removeItem(at: existing) }
    let marker = existing.appendingPathComponent("keep-me")
    try Data("kept".utf8).write(to: marker)

    // when
    let resolved = try StateRootResolver.createStateRoot(for: existing.path)

    // then
    #expect(resolved.standardizedFileURL == existing.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func anUncreatableStateRootIsAConfigErrorNamingThePath() throws {
    // given — a regular file stands where the parent directory would have to be
    let parent = try makeTemporaryRoot(prefix: "state-root-blocked")
    defer { try? FileManager.default.removeItem(at: parent) }
    let occupied = parent.appendingPathComponent("occupied")
    try Data("not a directory".utf8).write(to: occupied)
    let blocked = occupied.appendingPathComponent("root", isDirectory: true)

    // when
    let failure = #expect(throws: ConfigError.self) {
      try StateRootResolver.createStateRoot(for: blocked.path)
    }

    // then
    #expect(failure == .unwritableStateRoot(blocked.path))
  }

  // MARK: - The Default Root

  @Test func theDefaultRootIsTheDottedDirectoryInTheOwnersHome() throws {
    // given
    let expected = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(StateRootResolver.defaultDirectoryName, isDirectory: true)

    // when
    let resolved = try StateRootResolver.createStateRoot(for: nil)

    // then
    #expect(resolved.standardizedFileURL == expected.standardizedFileURL)
  }

  /// Copying `.env.example` verbatim leaves the variable blank, which must read as "unset" rather
  /// than as a relative path landing the state root in whatever directory the daemon was started in.
  @Test(arguments: ["", "   "])
  func aBlankPathFallsBackToTheDefaultRatherThanTheWorkingDirectory(raw: String) throws {
    // given
    let fromDefault = try StateRootResolver.createStateRoot(for: nil)

    // when
    let fromBlank = try StateRootResolver.createStateRoot(for: raw)

    // then
    #expect(fromBlank.standardizedFileURL == fromDefault.standardizedFileURL)
    #expect(
      fromBlank.standardizedFileURL
        != URL(fileURLWithPath: ".", isDirectory: true).standardizedFileURL
    )
  }

  // MARK: - One Implementation

  /// The promotion's whole point: daemon config resolves its state root through this resolver, so an
  /// owner cannot have `clawd run` and `clawd auth login` disagree about where credentials live — or
  /// have one of the two create the directory at a laxer mode than the other.
  @Test func appConfigResolvesTheSameRootAtTheSameMode() throws {
    // given
    let parent = try makeTemporaryRoot(prefix: "state-root-appconfig")
    defer { try? FileManager.default.removeItem(at: parent) }
    let named = parent.appendingPathComponent("daemon", isDirectory: true)

    // when
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: named.path,
      AppConfig.EnvKey.llmBaseURL: "http://localhost:1234/v1",
      AppConfig.EnvKey.llmModel: "gpt-4o",
    ])

    // then
    #expect(config.stateRoot.standardizedFileURL == named.standardizedFileURL)
    #expect(try posixPermissions(of: config.stateRoot) == 0o700)
  }

  @Test func appConfigFailsTheSameWayOnAnUncreatableRoot() throws {
    // given
    let parent = try makeTemporaryRoot(prefix: "state-root-appconfig-blocked")
    defer { try? FileManager.default.removeItem(at: parent) }
    let occupied = parent.appendingPathComponent("occupied")
    try Data("not a directory".utf8).write(to: occupied)
    let blocked = occupied.appendingPathComponent("root", isDirectory: true)

    // when
    let failure = #expect(throws: ConfigError.self) {
      try AppConfig.load(environment: [
        AppConfig.EnvKey.stateRoot: blocked.path,
        AppConfig.EnvKey.llmBaseURL: "http://localhost:1234/v1",
        AppConfig.EnvKey.llmModel: "gpt-4o",
      ])
    }

    // then
    #expect(failure == .unwritableStateRoot(blocked.path))
  }
}
