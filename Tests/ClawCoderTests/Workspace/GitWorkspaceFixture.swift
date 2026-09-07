import ClawCore
import ClawTestSupport
import Foundation
import Subprocess
import Testing

@testable import ClawCoder

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

struct GitWorkspaceFixture {
  let root: URL
  let source: URL

  init() async throws {
    root = try makeTemporaryRoot(prefix: "coder-workspace")
    source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try await git(["init", "--initial-branch=trunk"])
    try await git(["config", "user.email", "fixture@example.invalid"])
    try await git(["config", "user.name", "Workspace Fixture"])
    try write("file.txt", "original\n")
    try await commit()
  }

  @discardableResult
  func git(_ arguments: [String], at directory: URL? = nil) async throws -> String {
    let result = try await Subprocess.run(
      .path("/usr/bin/git"),
      arguments: Arguments(arguments),
      environment: .custom([
        "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
      ]),
      workingDirectory: FilePath((directory ?? source).path),
      output: .string(limit: 1024 * 1024),
      error: .string(limit: 64 * 1024)
    )
    try #require(result.terminationStatus == .exited(0), "\(arguments): \(result.standardError)")
    return result.standardOutput.trimmingCharacters(in: .newlines)
  }

  func write(_ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: source.appendingPathComponent(path))
  }

  func commit() async throws {
    try await git(["add", "."])
    try await git(["commit", "-m", "fixture"])
  }

  func request(
    mode: CoderWorkspaceMode = .inPlace,
    ref: String? = nil,
    deliverable: CoderDeliverable = .localChanges
  ) -> CoderRequest {
    CoderRequest(
      source: .local(path: source.path),
      task: "Fix the bug",
      workspace: mode,
      startRef: ref,
      deliverable: deliverable,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    )
  }

  func invocation(
    _ prepared: CoderPreparedRequest,
    timeout: Duration = .seconds(30)
  ) -> CoderInvocation {
    let id = UUID()
    return CoderInvocation(
      jobID: id,
      prepared: prepared,
      jobDirectory: root.appendingPathComponent("coder/jobs/\(id)").path,
      timeout: timeout
    )
  }

  func inspection() -> CoderGit {
    CoderGit(
      tracking: .job { _ in },
      phase: .inspect,
      deadline: ContinuousClock.now.advanced(by: .seconds(30))
    )
  }
}
