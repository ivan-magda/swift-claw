import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawCoder

@Suite struct CoderWorkspaceTests {
  @Test func dirtyInPlace() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write("already-deleted", "old file")
    try await fixture.commit()
    try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("already-deleted"))
    try fixture.write("file.txt", "staged work\n")
    try await fixture.git(["add", "file.txt"])
    try fixture.write("file.txt", "staged work plus bug\n")
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(
      fixture.request()
    )
    let state = try await CoderWorkspace().prepare(fixture.invocation(prepared)) { _ in }
    let baseline = try #require(state.baseline)

    // when
    try fixture.write("file.txt", "staged work corrected\n")
    try await fixture.commit()
    let current = try await RepositoryInventory.capture(
      at: state.directory,
      git: fixture.inspection()
    )

    // then
    #expect(try await fixture.git(["status", "--porcelain"]).isEmpty)
    #expect(current.changedPaths(comparedWith: baseline) == ["file.txt"])
    #expect(state.directory == fixture.source.resolvingSymlinksInPath().path)
    #expect(try await fixture.git(["branch", "--show-current"]) == "trunk")
  }

  @Test func unbornInPlace() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.git(["checkout", "--orphan", "unborn"])
    try fixture.write("file.txt", "uncommitted initial bug")
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(
      fixture.request()
    )

    // when
    let state = try await CoderWorkspace().prepare(fixture.invocation(prepared)) { _ in }
    let baseline = try #require(state.baseline)
    try fixture.write("file.txt", "corrected initial file")
    let current = try await RepositoryInventory.capture(
      at: state.directory,
      git: fixture.inspection()
    )

    // then
    #expect(state.startingCommit == nil)
    #expect(current.changedPaths(comparedWith: baseline) == ["file.txt"])
    #expect(try await fixture.git(["branch", "--show-current"]) == "unborn")
  }

  @Test func damagedHeadIsRefused() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let preparer = CoderRequestPreparer(executionPolicyID: "test")
    let prepared = try await preparer.prepare(fixture.request())
    let branch = try await fixture.git(["symbolic-ref", "HEAD"])
    let missingCommit = String(repeating: "1", count: 40)
    let branchFile = fixture.source.appendingPathComponent(".git").appendingPathComponent(branch)
    try Data("\(missingCommit)\n".utf8).write(to: branchFile)
    let currentIdentity = try await preparer.prepare(fixture.request())
    try #require(currentIdentity.checkoutPath == prepared.checkoutPath)
    try #require(currentIdentity.commonGitDirectory == prepared.commonGitDirectory)
    try #require(try await fixture.git(["rev-parse", "--verify", "HEAD"]) == missingCommit)
    await #expect(throws: CoderGitFailure.self) {
      try await fixture.inspection().commit("HEAD", at: fixture.source.path)
    }
    let invocation = fixture.invocation(prepared)

    // when
    let failure = await #expect(throws: CoderGitFailure.self) {
      try await CoderWorkspace().prepare(invocation) { _ in }
    }

    // then
    guard case .command = failure else {
      Issue.record("Damaged HEAD must fail preparation rather than become an unborn baseline")
      return
    }
    #expect(FileManager.default.fileExists(atPath: invocation.jobDirectory))
    #expect(
      try String(contentsOf: fixture.source.appendingPathComponent("file.txt"), encoding: .utf8)
        == "original\n"
    )
  }

  @Test func separateRef() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let commitA = try await fixture.git(["rev-parse", "HEAD"])
    try await fixture.git(["update-ref", "refs/remotes/archive/only-a", commitA])
    try await fixture.git(["checkout", "--orphan", "second"])
    try fixture.write("file.txt", "commit B\n")
    try await fixture.commit()
    try await fixture.git(["branch", "-D", "trunk"])
    try fixture.write("file.txt", "staged B\n")
    try await fixture.git(["add", "."])
    try fixture.write("file.txt", "dirty B\n")
    let indexBefore = try Data(contentsOf: fixture.source.appendingPathComponent(".git/index"))
    let sentinel = fixture.root.appendingPathComponent("hook-ran")
    let hook = fixture.source.appendingPathComponent(".git/hooks/post-checkout")
    try Data("#!/bin/sh\ntouch '\(sentinel.path)'\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try await fixture.git(["config", "core.fsmonitor", hook.path])
    try await fixture.git(["config", "fixture.secret", "must-not-copy"])
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(
      fixture.request(mode: .separate, ref: "refs/remotes/archive/only-a")
    )

    let processes = ProcessFixture()

    // when
    let state = try await CoderWorkspace().prepare(
      fixture.invocation(prepared),
      recordProcess: processes.record
    )
    let destination = URL(fileURLWithPath: state.directory)

    // then
    #expect(processes.receipt?.phase == .prepare)
    #expect(state.startingCommit == commitA)
    #expect(
      try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8)
        == "original\n"
    )
    #expect(
      try Data(contentsOf: fixture.source.appendingPathComponent(".git/index")) == indexBefore
    )
    #expect(
      try String(contentsOf: fixture.source.appendingPathComponent("file.txt"), encoding: .utf8)
        == "dirty B\n"
    )
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appendingPathComponent(".git/objects/info/alternates").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appendingPathComponent(".git/hooks/post-checkout").path
      )
    )
    #expect(try await fixture.git(["remote"], at: destination).isEmpty)
    let config = try String(
      contentsOf: destination.appendingPathComponent(".git/config"),
      encoding: .utf8
    )
    #expect(!config.contains("must-not-copy"))
    let sourceInodes = try objectInodes(in: fixture.source)
    let copyInodes = try objectInodes(in: destination)
    #expect(!sourceInodes.isEmpty && !copyInodes.isEmpty)
    #expect(sourceInodes.isDisjoint(with: copyInodes))
  }

  @Test func canonicalIdentity() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let linked = fixture.root.appendingPathComponent("linked")
    try await fixture.git(["worktree", "add", "--detach", linked.path])
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: linked)
    let request = CoderRequest(
      source: .local(path: alias.path),
      task: "Fix",
      workspace: .inPlace,
      startRef: nil,
      deliverable: .localChanges,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    )

    // when
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(request)

    // then
    #expect(prepared.checkoutPath == linked.resolvingSymlinksInPath().path)
    #expect(
      prepared.commonGitDirectory
        == fixture.source.appendingPathComponent(".git").resolvingSymlinksInPath().path
    )
  }

  @Test func frozenPublication() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.git(["remote", "add", "origin", "git@github.com:Owner/Repo.git"])
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(
      fixture.request(mode: .separate, deliverable: .pullRequest)
    )
    let state = try await CoderWorkspace().prepare(fixture.invocation(prepared)) { _ in }
    let destination = URL(fileURLWithPath: state.directory)
    #expect(
      try await fixture.git(["remote", "get-url", "origin"], at: destination)
        == "https://github.com/owner/repo.git"
    )
    #expect(prepared.publicationRepository == "owner/repo")

    // when
    try await fixture.git(["remote", "set-url", "origin", "https://github.com/other/destination"])

    // then
    await #expect(throws: CoderError.staleApproval) {
      try await CoderWorkspace().prepare(fixture.invocation(prepared)) { _ in }
    }
  }

  @Test(arguments: [
    [], ["https://example.com/owner/repo"], ["https://github.com/a/b", "https://github.com/c/d"],
    ["https://github.com/a/b/issues/4"],
  ])
  func invalidOrigin(urls: [String]) async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for url in urls { try await fixture.git(["config", "--add", "remote.origin.url", url]) }

    // when
    let failure = await #expect(throws: CoderError.self) {
      try await CoderRequestPreparer(executionPolicyID: "test").prepare(
        fixture.request(deliverable: .pullRequest)
      )
    }

    // then
    guard case .invalidRequest = failure else {
      Issue.record("Expected a clear invalid-origin refusal")
      return
    }
  }

  @Test func effectivePublicationOrigin() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.git(["remote", "add", "origin", "github:repo"])
    try await fixture.git([
      "config", "url.https://github.com/other/.insteadOf", "github:",
    ])
    try await fixture.git(["config", "remote.origin.pushurl", "git@github.com:other/repo.git"])
    let preparer = CoderRequestPreparer(executionPolicyID: "test")

    // when
    let prepared = try await preparer.prepare(fixture.request(deliverable: .pullRequest))
    try await fixture.git(["config", "remote.origin.pushurl", "https://github.com/third/repo"])

    // then
    #expect(prepared.publicationRepository == "other/repo")
    await #expect(throws: CoderError.self) {
      try await preparer.prepare(fixture.request(deliverable: .pullRequest))
    }
  }

  @Test func remoteAllocation() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = CoderRequest(
      source: .githubIssue(url: "https://github.com/Owner/Repo/issues/42"),
      task: nil,
      workspace: .separate,
      startRef: "release",
      deliverable: .pullRequest,
      baseBranch: "stable",
      instructions: nil,
      publishExistingChanges: false
    )
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(request)
    let invocation = fixture.invocation(prepared)
    #expect(!FileManager.default.fileExists(atPath: invocation.jobDirectory))

    // when
    let state = try await CoderWorkspace().prepare(invocation) { _ in
      Issue.record("Remote allocation must not launch a command")
    }

    // then
    #expect(prepared.publicationRepository == "owner/repo")
    #expect(prepared.request.baseBranch == "stable")
    #expect(state.baseline == nil)
    #expect(state.startingCommit == nil)
    #expect(try entryNames(in: URL(fileURLWithPath: state.directory)).isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: invocation.jobDirectory)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test func inventoryKinds() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write(".gitignore", "ignored\n")
    try fixture.write("executable", "same contents")
    try FileManager.default.createSymbolicLink(
      atPath: fixture.source.appendingPathComponent("link").path,
      withDestinationPath: "/outside/first"
    )
    try await fixture.commit()
    let baseline = try await RepositoryInventory.capture(
      at: fixture.source.path,
      git: fixture.inspection()
    )

    // when
    try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("file.txt"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.source.appendingPathComponent("executable").path
    )
    try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("link"))
    try FileManager.default.createSymbolicLink(
      atPath: fixture.source.appendingPathComponent("link").path,
      withDestinationPath: "/outside/second"
    )
    try fixture.write("new\nfile", "untracked")
    try fixture.write("ignored", "ignored")
    let current = try await RepositoryInventory.capture(
      at: fixture.source.path,
      git: fixture.inspection()
    )

    // then
    #expect(
      current.changedPaths(comparedWith: baseline) == [
        "executable", "file.txt", "link", "new\nfile",
      ]
    )
  }

  @Test(arguments: [false, true])
  func unavailableInventory(symlinkAncestor: Bool) async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(
      fixture.request()
    )
    if symlinkAncestor {
      let nested = fixture.source.appendingPathComponent("nested")
      let outside = fixture.root.appendingPathComponent("outside")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      try fixture.write("nested/tracked", "must not read through the link")
      try await fixture.commit()
      try FileManager.default.moveItem(at: nested, to: outside)
      try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
    } else {
      try Data(repeating: 1, count: RepositoryInventory.byteLimit + 1).write(
        to: fixture.source.appendingPathComponent("large")
      )
    }

    // when
    let state = try await CoderWorkspace().prepare(fixture.invocation(prepared)) { _ in }

    // then
    #expect(state.baseline == nil)
    #expect(FileManager.default.fileExists(atPath: state.directory))
  }

  @Test func rejectsFailedSupervision() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let git = CoderGit(
      tracking: .job { event in
        if case .didLaunch(let receipt) = event {
          let pid = try #require(receipt.pid)
          let observationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
          while try !CoderProcessIdentity.childExited(pid) {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < observationDeadline)
            try await Task.sleep(for: ManagedCoderProcessGroup.pollInterval)
          }
          throw FixtureFailure.rejected
        }
      },
      phase: .prepare,
      deadline: ContinuousClock.now.advanced(by: .seconds(30))
    )

    // when
    let failure = await #expect(throws: CoderGitFailure.self) {
      try await git.run(["rev-parse", "HEAD"], at: fixture.source.path)
    }

    // then
    guard case .supervision(let result) = failure else {
      Issue.record("Expected supervised Git failure")
      return
    }
    #expect(result.exitCode == 0)
    #expect(result.cleanupResolved)
    #expect(result.supervisionFailed)
  }

  @Test func exhaustedDeadline() async throws {
    // given
    let fixture = try await GitWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let prepared = try await CoderRequestPreparer(executionPolicyID: "test").prepare(
      fixture.request()
    )
    let invocation = fixture.invocation(prepared, timeout: .seconds(30))
    let expired = ContinuousClock.now.advanced(by: .seconds(-1))

    // when
    let failure = await #expect(throws: CoderGitFailure.self) {
      try await CoderWorkspace().prepare(invocation, deadline: expired) { _ in
        Issue.record("Expired job must not launch")
      }
    }

    // then
    guard case .deadline = failure else {
      Issue.record("Expected exhausted shared deadline")
      return
    }
  }
}

// MARK: - Object independence

private extension CoderWorkspaceTests {
  func objectInodes(in directory: URL) throws -> Set<UInt64> {
    let objects = directory.appendingPathComponent(".git/objects")
    let enumerator = try #require(
      FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)
    )
    var inodes = Set<UInt64>()
    for case let url as URL in enumerator {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let isRegular = attributes[.type] as? FileAttributeType == .typeRegular
      if isRegular, let inode = attributes[.systemFileNumber] as? NSNumber {
        inodes.insert(inode.uint64Value)
      }
    }
    return inodes
  }
}
