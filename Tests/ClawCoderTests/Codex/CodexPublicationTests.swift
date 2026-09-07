import ClawCore
import Foundation
import Testing

@testable import ClawCoder

extension CodexBackendTests {
  @Test(arguments: [
    "confirmed", "wrongRepository", "wrongHead", "wrongHeadOID", "wrongBase", "defaultMismatch",
    "unavailable",
    "missingURL",
  ])
  func publicationMatrix(mode: String) async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    try await fixture.git.git(["remote", "add", "origin", "https://github.com/owner/project.git"])
    let commit = try await fixture.git.git(["rev-parse", "HEAD"])
    let url = "https://github.com/owner/project/pull/42"
    try fixture.report([
      "pr_url": mode == "missingURL" ? NSNull() : url,
      "branch": "trunk", "base_branch": "release", "commit": commit,
    ])
    let pull: [String: Any] = [
      "url": mode == "wrongRepository" ? "https://github.com/other/project/pull/42" : url,
      "headRefName": mode == "wrongHead" ? "other-head" : "trunk",
      "headRefOid": mode == "wrongHeadOID" ? String(repeating: "a", count: 40) : commit,
      "baseRefName": mode == "wrongBase" ? "wrong-base" : "release",
      "author": ["login": "github-actor"],
    ]
    try JSONSerialization.data(withJSONObject: pull).write(
      to: fixture.git.root.appendingPathComponent("pull")
    )
    try fixture.script(
      "gh",
      """
      #!/bin/sh
      root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      printf '%s\\0' "$@" >> "$root/gh-argv"
      if [ "$1" = repo ]; then printf '{"defaultBranchRef":{"name":"default-base"}}'; exit 0; fi
      \(mode == "unavailable" ? "exit 1" : "cat \"$root/pull\"")
      """
    )
    let request = CoderRequest(
      source: .local(path: fixture.git.source.path),
      task: "Fix and publish",
      workspace: .inPlace,
      startRef: nil,
      deliverable: .pullRequest,
      baseBranch: mode == "defaultMismatch" ? nil : "release",
      instructions: nil,
      publishExistingChanges: false
    )
    let invocation = try await fixture.invocation(request)

    // when
    let result = await (try fixture.backend()).run(invocation) { _ in }

    // then
    if mode == "confirmed" {
      #expect(result.state == .succeeded)
      #expect(result.publication == .confirmed(url: url))
      #expect(result.githubActor == "github-actor")
      #expect(result.commitAuthor?.contains("Workspace Fixture") == true)
      #expect(try fixture.read("gh-argv").contains("--repo\0owner/project"))
    } else {
      #expect(result.state == .failed)
      #expect(result.failure?.stage == .inspection)
      #expect(result.publication == .unknown(reportedURL: mode == "missingURL" ? nil : url))
    }
  }

  @Test(arguments: [true, false]) func remoteEvidence(cloned: Bool) async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    let starting = try await fixture.git.git(["rev-parse", "HEAD"])
    try fixture.report(["starting_commit": starting])
    if cloned {
      try fixture.write("action", "/usr/bin/git clone -- \"$(dirname \"$0\")/source\" .")
    }
    let request = CoderRequest(
      source: .githubRepository(url: "https://github.com/owner/project"),
      task: "Fix",
      workspace: .separate,
      startRef: nil,
      deliverable: .localChanges,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    )
    let invocation = try await fixture.invocation(request)

    // when
    let result = await (try fixture.backend()).run(invocation) { _ in }

    // then
    #expect(result.state == (cloned ? .succeeded : .failed))
    if !cloned { #expect(result.failure?.stage == .inspection) }
    #expect(result.startingCommit == starting)
    #expect(!result.baselineObserved)
    #expect(result.changedFiles == nil)
    #expect(result.commit == (cloned ? starting : nil))
  }
}

extension CodexBackendTests {
  @Test(arguments: [false, true]) func localUnavailableInventory(unborn: Bool) async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    if unborn {
      try FileManager.default.removeItem(at: fixture.git.source.appendingPathComponent(".git"))
      try await fixture.git.git(["init", "--initial-branch=unborn"])
    }
    let starting = unborn ? nil : try await fixture.git.git(["rev-parse", "HEAD"])
    try Data(repeating: 1, count: RepositoryInventory.byteLimit + 1).write(
      to: fixture.git.source.appendingPathComponent("oversized")
    )
    try fixture.report(["starting_commit": String(repeating: "a", count: 40)])
    let invocation = try await fixture.invocation()

    // when
    let result = await (try fixture.backend()).run(invocation) { _ in }

    // then
    #expect(result.state == .succeeded)
    #expect(result.baselineObserved)
    #expect(result.startingCommit == starting)
    #expect(result.commit == starting)
    #expect(result.changedFiles == nil)
  }
}
