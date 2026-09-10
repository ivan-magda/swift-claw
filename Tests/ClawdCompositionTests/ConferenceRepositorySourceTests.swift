import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Testing

@testable import clawd

@Suite struct ConferenceRepositorySourceTests {
  @Test func transientCheckoutFailurePreservesReusableSource() async throws {
    // given
    let fixture = try await ConferenceSourceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lock = fixture.cache.appendingPathComponent(".git/index.lock")
    try Data().write(to: lock)
    let source = ConferenceRepositorySource(
      stateRoot: fixture.root,
      git: ConferenceOfflineSourceGit()
    )

    // when
    await #expect(throws: ConferenceSourceError.gitFailed) {
      try await source.prepare(fixture.item)
    }

    // then
    try #require(FileManager.default.fileExists(atPath: lock.path))
    try FileManager.default.removeItem(at: lock)
    #expect(try await source.prepare(fixture.item) == fixture.cache.path)
  }

  @Test func invalidCacheAndFailedReplacementLeaveNoIncompleteSource() async throws {
    // given
    let fixture = try await ConferenceSourceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: fixture.cache.appendingPathComponent(".git"))
    let source = ConferenceRepositorySource(
      stateRoot: fixture.root,
      git: ConferenceOfflineSourceGit()
    )

    // when
    await #expect(throws: ConferenceSourceError.gitFailed) {
      try await source.prepare(fixture.item)
    }

    // then
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
  }
}

private struct ConferenceSourceFixture {
  let root: URL
  let cache: URL
  let item: ConferenceCase

  init() async throws {
    root = try makeTemporaryRoot(prefix: "conference-source").resolvingSymlinksInPath()
    cache = root.appendingPathComponent("conference-source/day-1")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    _ = try await conferenceGit(["init", cache.path])
    try Data("baseline\n".utf8).write(to: cache.appendingPathComponent("feature.txt"))
    _ = try await conferenceGit(["-C", cache.path, "add", "feature.txt"])
    _ = try await conferenceGit([
      "-C", cache.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
      "commit", "-m", "Baseline",
    ])
    let baseline = try await conferenceGit(["-C", cache.path, "rev-parse", "HEAD"])
    let repository = "https://github.com/wowlocal/crew18-sim"
    _ = try await conferenceGit(["-C", cache.path, "remote", "add", "origin", repository])
    item = ConferenceCase(
      id: "day-1",
      title: "Accessibility",
      prompt: "Restore accessibility labels.",
      repositoryURL: repository,
      baselineRef: baseline,
      baseBranch: "challenge/day-1"
    )
  }
}

private struct ConferenceOfflineSourceGit: SubprocessRunning {
  private let local = SwiftSubprocessRunner(
    executablePath: "/usr/bin/git",
    environmentForTesting: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
  )

  func run(_ command: SubprocessCommand) async -> SubprocessResult {
    guard command.arguments.contains("clone"), let destination = command.arguments.last else {
      return await local.run(command)
    }
    try? FileManager.default.createDirectory(
      atPath: destination,
      withIntermediateDirectories: true
    )
    let empty = CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false)
    return SubprocessResult(
      termination: .exited(128),
      stdout: empty,
      stderr: empty,
      processIdentifier: nil
    )
  }
}
