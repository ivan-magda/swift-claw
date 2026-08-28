import ClawSubprocess
import Foundation

enum EvaluationWorkerTermination: String, Sendable, Equatable {
  case completed
  case interrupted
  case rejected
}

struct EvaluationWorkerLaunchResult: Sendable, Equatable {
  let termination: EvaluationWorkerTermination
  let processID: Int32?
}

protocol EvaluationWorkerLaunching: Sendable {
  func launch(
    kind: EvaluationWorkerInvocationKind,
    executablePath: String,
    invocationPath: String,
    sealedOutputKey: Data?
  ) async -> EvaluationWorkerLaunchResult
}

struct EvaluationSubprocessWorkerLauncher: EvaluationWorkerLaunching {
  func launch(
    kind: EvaluationWorkerInvocationKind,
    executablePath: String,
    invocationPath: String,
    sealedOutputKey: Data?
  ) async -> EvaluationWorkerLaunchResult {
    let rawExecutable = URL(fileURLWithPath: executablePath)
    let rawInvocation = URL(fileURLWithPath: invocationPath)
    do {
      try EvaluationPathSecurity.rejectSymlinkComponents(
        in: [rawExecutable, rawInvocation]
      )
    } catch {
      return EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let executable = rawExecutable.standardizedFileURL
    let invocation = rawInvocation.standardizedFileURL
    guard
      FileManager.default.isExecutableFile(atPath: executable.path),
      FileManager.default.isReadableFile(atPath: invocation.path)
    else {
      return EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let runner = SwiftSubprocessRunner(executablePath: executable.path)
    let result = await runner.run(
      SubprocessCommand(
        arguments: [
          kind == .attempt ? "worker" : "canary-process",
          "--invocation", invocation.path,
        ] + (sealedOutputKey == nil ? [] : ["--sealed-output-key-stdin"]),
        timeout: .seconds(
          (kind == .attempt ? 1 : 2) * PageEvaluationContract.runBudget.wallClockDeadlineSeconds
            + 30
        ),
        captureLimit: 8_192,
        teardownGracePeriod: .seconds(5),
        standardInput: sealedOutputKey ?? Data()
      )
    )
    switch result.termination {
    case .exited(0):
      return EvaluationWorkerLaunchResult(
        termination: .completed,
        processID: result.processIdentifier
      )
    case .signaled, .timedOut, .cancelled:
      return EvaluationWorkerLaunchResult(
        termination: .interrupted,
        processID: result.processIdentifier
      )
    case .exited, .startFailed:
      return EvaluationWorkerLaunchResult(
        termination: .rejected,
        processID: result.processIdentifier
      )
    }
  }
}
