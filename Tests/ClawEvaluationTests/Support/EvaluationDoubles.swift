import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

struct StaticEvaluationFreezeVerifier: EvaluationFreezeVerifying {
  let context: EvaluationFreezeContext

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    context
  }
}

struct ScriptedEvaluationWorkerObservation: Sendable, Equatable {
  let kind: EvaluationWorkerInvocationKind
  let attemptIDs: [String]
  let sealedOutputKeyWasPresent: Bool
}

actor ScriptedEvaluationWorkerLauncher: EvaluationWorkerLaunching {
  typealias Script =
    @Sendable (
      EvaluationWorkerInvocation,
      [EvaluationAttemptConfiguration],
      Data?
    ) async throws -> EvaluationWorkerLaunchResult

  private let script: Script
  private var recorded: [ScriptedEvaluationWorkerObservation] = []
  private var recordedFailures: [String] = []

  init(script: @escaping Script) {
    self.script = script
  }

  var observations: [ScriptedEvaluationWorkerObservation] { recorded }
  var failures: [String] { recordedFailures }

  func launch(
    kind: EvaluationWorkerInvocationKind,
    executablePath _: String,
    invocationPath: String,
    sealedOutputKey: Data?
  ) async -> EvaluationWorkerLaunchResult {
    do {
      let invocation = try EvaluationJSONFile.decode(
        EvaluationWorkerInvocation.self,
        from: URL(fileURLWithPath: invocationPath)
      )
      let configurations = try Self.configurations(for: invocation)
      recorded.append(
        ScriptedEvaluationWorkerObservation(
          kind: kind,
          attemptIDs: configurations.map(\.attemptID),
          sealedOutputKeyWasPresent: sealedOutputKey != nil
        )
      )
      return try await script(invocation, configurations, sealedOutputKey)
    } catch {
      recordedFailures.append(String(reflecting: error))
      return EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
  }

  private static func configurations(
    for invocation: EvaluationWorkerInvocation
  ) throws -> [EvaluationAttemptConfiguration] {
    switch invocation.kind {
    case .attempt:
      return [
        try EvaluationJSONFile.decode(
          EvaluationAttemptConfiguration.self,
          from: URL(fileURLWithPath: invocation.configurationPath)
        )
      ]
    case .canaryProcess:
      let batch = try EvaluationJSONFile.decode(
        EvaluationWorkerBatchConfiguration.self,
        from: URL(fileURLWithPath: invocation.configurationPath)
      )
      return try batch.attemptConfigurationPaths.map { path in
        try EvaluationJSONFile.decode(
          EvaluationAttemptConfiguration.self,
          from: URL(fileURLWithPath: path)
        )
      }
    }
  }
}

struct StaticEvaluationProtectedArtifactRunner: EvaluationProtectedArtifactRunning {
  let output: Data

  func run(
    relativeExecutablePath _: String,
    arguments _: [String],
    protectedOutputURLs _: [URL],
    freeze _: EvaluationFreezeContext,
    captureLimit _: Int
  ) async throws -> Data {
    output
  }
}

actor ScriptedEvaluationProtectedArtifactRunner: EvaluationProtectedArtifactRunning {
  struct Invocation: Sendable, Equatable {
    let relativeExecutablePath: String
    let arguments: [String]
    let protectedOutputURLs: [URL]
  }

  private let output: Data
  private var storedInvocations: [Invocation] = []

  init(output: Data) {
    self.output = output
  }

  var invocations: [Invocation] { storedInvocations }

  func run(
    relativeExecutablePath: String,
    arguments: [String],
    protectedOutputURLs: [URL],
    freeze _: EvaluationFreezeContext,
    captureLimit _: Int
  ) async throws -> Data {
    storedInvocations.append(
      Invocation(
        relativeExecutablePath: relativeExecutablePath,
        arguments: arguments,
        protectedOutputURLs: protectedOutputURLs
      )
    )
    for url in protectedOutputURLs {
      try EvaluationDurablePublication.publish(output, to: url)
    }
    return output
  }
}
