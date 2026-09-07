import ClawCore
import Foundation

struct CoderGit: Sendable {
  static let outputByteLimit = 1024 * 1024
  let tracking: CoderCommandTracking
  let phase: CoderProcessPhase
  let deadline: ContinuousClock.Instant

  @discardableResult
  func run(_ arguments: [String], at directory: String) async throws -> Data {
    try Task.checkCancellation()
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw CoderGitFailure.deadline
    }
    let output = GitOutput()
    let command = CoderCommand(
      executable: "/usr/bin/git",
      arguments: [
        "--no-optional-locks", "--no-pager",
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
        "-c", "core.attributesFile=/dev/null", "-c", "core.excludesFile=/dev/null",
        "-c", "diff.external=", "-c", "protocol.allow=never", "-c", "protocol.file.allow=always",
        "-c", "maintenance.auto=false", "-c", "gc.auto=0",
      ] + arguments,
      environment: [
        "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1", "LC_ALL": "C",
      ],
      workingDirectory: directory,
      input: "",
      phase: phase,
      timeout: remaining
    )
    let result = await CoderCommandRunner().run(command, tracking: tracking) { bytes in
      await output.append(bytes)
    }
    guard !result.supervisionFailed, !result.cancelled, !result.timedOut, result.cleanupResolved
    else {
      throw CoderGitFailure.supervision(result)
    }
    guard result.exitCode == 0, result.signal == nil else {
      throw CoderGitFailure.command(result)
    }
    return try await output.value()
  }

  func text(_ arguments: [String], at directory: String) async throws -> String {
    let bytes = try await run(arguments, at: directory)
    guard let text = String(data: bytes, encoding: .utf8), text.hasSuffix("\n") else {
      throw CoderGitFailure.output
    }
    return String(text.dropLast())
  }

  func commit(_ ref: String, at directory: String) async throws -> String {
    let sha = try await text(
      ["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"],
      at: directory
    )
    guard [40, 64].contains(sha.utf8.count),
      sha.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      })
    else {
      throw CoderGitFailure.output
    }
    return sha
  }
}

enum CoderGitFailure: Error {
  case deadline
  case command(CoderCommandResult)
  case output
  case supervision(CoderCommandResult)
}

private actor GitOutput {
  private var bytes = Data()
  private var oversized = false

  func append(_ data: Data) {
    let available = max(0, CoderGit.outputByteLimit - bytes.count)
    if data.count > available { oversized = true }
    bytes.append(data.prefix(available))
  }

  func value() throws -> Data {
    guard !oversized else {
      throw CoderGitFailure.output
    }
    return bytes
  }
}
