import ClawCore
import ClawSubprocess
import Foundation

struct ConferenceRepositorySource: Sendable {
  private let stateRoot: URL
  private let sourceHome: URL
  private let git: any SubprocessRunning

  init(stateRoot: URL, git: (any SubprocessRunning)? = nil) {
    self.stateRoot = stateRoot.resolvingSymlinksInPath().standardizedFileURL
    sourceHome = stateRoot.appendingPathComponent("conference-source-home", isDirectory: true)
    self.git =
      git
      ?? SwiftSubprocessRunner(
        executablePath: "/usr/bin/git",
        environmentForTesting: [
          "HOME": sourceHome.path,
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
    try FileManager.default.createDirectory(
      at: sourceHome,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let destination = root.appendingPathComponent(item.id, isDirectory: true)

    if FileManager.default.fileExists(atPath: destination.path) {
      do {
        try await validateCachedSource(item, at: destination)
        return destination.path
      } catch ConferenceSourceError.baselineMismatch, ConferenceSourceError.sourceMismatch {
        try FileManager.default.removeItem(at: destination)
      }
    }

    do {
      try await run([
        "clone", "--no-checkout", "--no-tags", "--template=", "--",
        item.repositoryURL, destination.path,
      ])
      try await validateCachedSource(item, at: destination)
      return destination.path
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }
}

private extension ConferenceRepositorySource {
  func validateCachedSource(_ item: ConferenceCase, at destination: URL) async throws {
    let checkout = try await output(
      ["-C", destination.path, "rev-parse", "--show-toplevel"],
      failure: .sourceMismatch
    )
    let canonicalCheckout = URL(fileURLWithPath: checkout)
      .resolvingSymlinksInPath().standardizedFileURL.path
    guard canonicalCheckout == destination.resolvingSymlinksInPath().standardizedFileURL.path else {
      throw ConferenceSourceError.sourceMismatch
    }

    let origin = try await output(
      ["-C", destination.path, "remote", "get-url", "--all", "origin"],
      failure: .sourceMismatch
    )
    guard origin == item.repositoryURL else {
      throw ConferenceSourceError.sourceMismatch
    }

    let resolved = try await output(
      [
        "-C", destination.path,
        "rev-parse", "--verify", "--end-of-options", "\(item.baselineRef)^{commit}",
      ],
      failure: .baselineMismatch
    )
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
    let status = try await output([
      "-C", destination.path, "status", "--porcelain=v1",
    ])
    guard status.isEmpty else {
      throw ConferenceSourceError.sourceMismatch
    }
  }

  func run(_ arguments: [String]) async throws {
    let result = await git.run(command(arguments))
    if Task.isCancelled || result.termination == .cancelled {
      throw CancellationError()
    }
    guard result.termination == .exited(0), !result.stderr.truncated else {
      throw ConferenceSourceError.gitFailed
    }
  }

  func output(
    _ arguments: [String],
    failure: ConferenceSourceError = .gitFailed
  ) async throws -> String {
    let result = await git.run(command(arguments))
    if Task.isCancelled || result.termination == .cancelled {
      throw CancellationError()
    }
    guard result.termination == .exited(0) else {
      if case .exited = result.termination {
        throw failure
      }
      throw ConferenceSourceError.gitFailed
    }
    guard !result.stdout.truncated,
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
