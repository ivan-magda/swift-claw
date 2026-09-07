import ClawCore
import Foundation

struct CodexCommandContext: Sendable {
  let environment: [String: String]
  let directory: String
  let tracking: CoderCommandTracking
  let phase: CoderProcessPhase
  let deadline: ContinuousClock.Instant

  func command(executable: String, arguments: [String], input: String = "") throws -> CoderCommand {
    try Task.checkCancellation()
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw CoderGitFailure.deadline
    }
    return CoderCommand(
      executable: executable,
      arguments: arguments,
      environment: environment,
      workingDirectory: directory,
      input: input,
      phase: phase,
      timeout: remaining
    )
  }

  func capture(executable: String, arguments: [String]) async throws -> Data {
    let output = CodexCommandOutput()
    let command = try command(executable: executable, arguments: arguments)
    let result = await CoderCommandRunner().run(command, tracking: tracking) { bytes in
      try await output.append(bytes)
    }
    guard result.exitCode == 0, result.signal == nil, !result.supervisionFailed,
      !result.cancelled, !result.timedOut, result.cleanupResolved
    else {
      throw CoderGitFailure.supervision(result)
    }
    return await output.bytes
  }

  func compatibility(executable: String) async throws -> String {
    let version = try await capture(executable: executable, arguments: ["--version"])
    let help = try await capture(executable: executable, arguments: ["exec", "--help"])
    guard let helpText = String(data: help, encoding: .utf8),
      let versionText = String(data: version, encoding: .utf8)
    else {
      throw CoderError.unavailable("Codex CLI probe returned invalid UTF-8.")
    }
    let flags = Set(
      helpText.split {
        $0.isWhitespace || ",=[]".contains($0)
      }.map(String.init)
    )
    let missing = CodexInvocation.requiredFlags.filter {
      !flags.contains($0)
    }
    guard missing.isEmpty else {
      throw CoderError.unavailable(
        "Codex CLI lacks required flags: \(missing.joined(separator: ", "))."
      )
    }
    let text = versionText.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !text.isEmpty else {
      throw CoderError.unavailable("Codex CLI returned no version.")
    }
    return text
  }
}

private actor CodexCommandOutput {
  private(set) var bytes = Data()

  func append(_ data: Data) throws {
    guard bytes.count + data.count <= CoderCommandRunner.diagnosticByteLimit else {
      throw CodexProtocolFailure.invalidEvents
    }
    bytes.append(data)
  }
}
