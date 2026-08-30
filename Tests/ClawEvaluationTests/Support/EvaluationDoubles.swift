import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

struct StaticEvaluationFreezeVerifier: EvaluationFreezeVerifying {
  let liveContext: EvaluationFreezeContext
  let localContext: EvaluationFreezeContext
  let beforeReturningLiveContext: @Sendable () throws -> Void

  init(
    context: EvaluationFreezeContext,
    beforeReturningLiveContext: @escaping @Sendable () throws -> Void = {}
  ) {
    liveContext = context
    localContext = context
    self.beforeReturningLiveContext = beforeReturningLiveContext
  }

  init(
    liveContext: EvaluationFreezeContext,
    localContext: EvaluationFreezeContext,
    beforeReturningLiveContext: @escaping @Sendable () throws -> Void = {}
  ) {
    self.liveContext = liveContext
    self.localContext = localContext
    self.beforeReturningLiveContext = beforeReturningLiveContext
  }

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    try beforeReturningLiveContext()
    return liveContext
  }

  func verifyLocal(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    localContext
  }
}

actor SequencedEvaluationFreezeVerifier: EvaluationFreezeVerifying {
  private let liveContexts: [EvaluationFreezeContext]
  private let localContext: EvaluationFreezeContext
  private let beforeReturningLiveContext: @Sendable (Int) throws -> Void
  private var liveIndex = 0

  init(
    liveContexts: [EvaluationFreezeContext],
    localContext: EvaluationFreezeContext,
    beforeReturningLiveContext: @escaping @Sendable (Int) throws -> Void = { _ in }
  ) {
    self.liveContexts = liveContexts
    self.localContext = localContext
    self.beforeReturningLiveContext = beforeReturningLiveContext
  }

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    guard liveContexts.indices.contains(liveIndex) else {
      throw EvaluationHarnessTestError.unexpectedFreezeCall
    }
    try beforeReturningLiveContext(liveIndex)
    defer { liveIndex += 1 }
    return liveContexts[liveIndex]
  }

  func verifyLocal(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    localContext
  }
}

func evaluationContextChangingApprovalBody(
  _ context: EvaluationFreezeContext,
  to bodySHA256: String = String(repeating: "f", count: 64)
) -> EvaluationFreezeContext {
  let comment = context.receipt.comment
  let changedComment = EvaluationFreezeReceipt.Comment(
    id: comment.id,
    nodeID: comment.nodeID,
    author: comment.author,
    createdAt: comment.createdAt,
    updatedAt: comment.updatedAt,
    bodySHA256: bodySHA256
  )
  let receipt = context.receipt
  let changedReceipt = EvaluationFreezeReceipt(
    schemaVersion: receipt.schemaVersion,
    status: receipt.status,
    verifiedAt: receipt.verifiedAt,
    decision: receipt.decision,
    experiment: receipt.experiment,
    manifest: receipt.manifest,
    verifier: receipt.verifier,
    verifierModules: receipt.verifierModules,
    freezeCommit: receipt.freezeCommit,
    comment: changedComment,
    executable: receipt.executable
  )
  return EvaluationFreezeContext(
    repositoryRoot: context.repositoryRoot,
    manifest: context.manifest,
    receipt: changedReceipt,
    runtime: context.runtime,
    runOrderJSON: context.runOrderJSON
  )
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
    credentialStateRoot _: String,
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

enum EvaluationHarnessTestError: Error {
  case unexpectedFreezeCall
  case unexpectedCanaryInvocation
}

actor FailingStreamingProvider: LLMProvider {
  let cause: ProviderError
  let accounting: ProviderFailureAccounting
  private(set) var streamCalls = 0

  init(
    cause: ProviderError,
    accounting: ProviderFailureAccounting = .mayHaveStarted(observing: 1)
  ) {
    self.cause = cause
    self.accounting = accounting
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    Issue.record("evaluation streaming must not fall back to a buffered provider call")
    throw cause
  }

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { _ in
      await self.recordStreamCall()
      return .failed(
        ProviderFailure(
          cause: self.cause,
          accounting: self.accounting
        )
      )
    }
  }

  private func recordStreamCall() {
    streamCalls += 1
  }
}

func scriptedTwoRoundResponses(
  requestedPath: String = PageEvaluationContract.inputFileName,
  firstUsage: ChatUsage? = .zero
) -> [ChatResponse] {
  [
    ChatResponse(
      content: "",
      finishReason: "tool_calls",
      usage: firstUsage,
      costFromProvider: nil,
      toolCalls: [
        ToolCall(
          id: "read-input",
          name: EvaluationToolContract.requiredToolName,
          argumentsJSON: #"{"path":"\#(requestedPath)"}"#
        )
      ],
      reportedModel: PageEvaluationContract.wireModel
    ),
    ChatResponse(
      content: #"{"schema_version":1}"#,
      finishReason: "stop",
      usage: .zero,
      costFromProvider: nil,
      reportedModel: PageEvaluationContract.wireModel
    ),
  ]
}
