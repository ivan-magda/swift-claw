import ClawCore
import ClawSubprocess
import Foundation

struct ConferenceRepositorySource: Sendable {
  private let stateRoot: URL
  private let git: SwiftSubprocessRunner

  init(stateRoot: URL) {
    self.stateRoot = stateRoot.resolvingSymlinksInPath().standardizedFileURL
    git = SwiftSubprocessRunner(
      executablePath: "/usr/bin/git",
      environmentForTesting: [
        "HOME": stateRoot.appendingPathComponent("conference-source-home").path,
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
      ]
    )
  }

  func prepare(_ item: ConferenceCase) async throws -> String {
    let root = stateRoot.appendingPathComponent("conference-source", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let destination = root.appendingPathComponent(item.id, isDirectory: true)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }

    try await run([
      "clone", "--no-checkout", "--no-tags", "--template=", "--",
      item.repositoryURL, destination.path,
    ])
    let resolved = try await output([
      "-C", destination.path,
      "rev-parse", "--verify", "--end-of-options", "\(item.baselineRef)^{commit}",
    ])
    guard resolved.caseInsensitiveCompare(item.baselineRef) == .orderedSame else {
      throw ConferenceSourceError.baselineMismatch
    }
    try await run([
      "-C", destination.path,
      "checkout", "--detach", "--force", item.baselineRef, "--",
    ])
    let head = try await output([
      "-C", destination.path, "rev-parse", "--verify", "HEAD^{commit}",
    ])
    guard head.caseInsensitiveCompare(item.baselineRef) == .orderedSame else {
      throw ConferenceSourceError.baselineMismatch
    }
    return destination.path
  }
}

enum ConferenceSourceError: Error, Sendable, Equatable {
  case gitFailed
  case baselineMismatch
}

private extension ConferenceRepositorySource {
  func run(_ arguments: [String]) async throws {
    let result = await git.run(command(arguments))
    if Task.isCancelled || result.termination == .cancelled {
      throw CancellationError()
    }
    guard result.termination == .exited(0), !result.stderr.truncated else {
      throw ConferenceSourceError.gitFailed
    }
  }

  func output(_ arguments: [String]) async throws -> String {
    let result = await git.run(command(arguments))
    if Task.isCancelled || result.termination == .cancelled {
      throw CancellationError()
    }
    guard result.termination == .exited(0),
      !result.stdout.truncated,
      let text = String(data: result.stdout.bytes, encoding: .utf8)
    else {
      throw ConferenceSourceError.gitFailed
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func command(_ arguments: [String]) -> SubprocessCommand {
    SubprocessCommand(
      arguments: [
        "--no-optional-locks", "--no-pager",
        "-c", "credential.helper=",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.attributesFile=/dev/null",
        "-c", "core.excludesFile=/dev/null",
        "-c", "protocol.file.allow=never",
        "-c", "maintenance.auto=false",
        "-c", "gc.auto=0",
      ] + arguments,
      timeout: .seconds(120),
      captureLimit: 64 * 1024,
      teardownGracePeriod: .seconds(2),
      environmentKeysToRemove: [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "SSH_AUTH_SOCK", "GIT_ASKPASS",
      ]
    )
  }
}
