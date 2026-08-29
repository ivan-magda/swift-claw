import ArgumentParser
import ClawEvaluation
import Foundation

@main
struct ClawEvalCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claw-eval",
    abstract: "Frozen controller/worker harness for scheduled-task learning experiments.",
    subcommands: [
      Page.self,
      Worker.self,
      LearningCall.self,
      CanaryProcess.self,
      InspectPolicy.self,
      AuthLogin.self,
    ]
  )

  struct Page: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "page",
      abstract: "Run the manifest-derived page-change experiment."
    )

    @Option(help: "Absolute path to the D6-approved EvaluationFreezeInputs JSON.")
    var freezeInputs: String

    mutating func run() async throws {
      let data = try await EvaluationPageExperiment().run(freezeInputsPath: freezeInputs)
      FileHandle.standardOutput.write(data)
    }
  }

  struct AuthLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "auth-login",
      abstract: "Sign in only for one D6-approved evaluation root and frozen model."
    )

    @Option(help: "Absolute path to JSON containing the approved EvaluationFreezeInputs.")
    var freezeInputs: String

    @Option(help: "Absolute path to the approved evaluation runtime.json.")
    var runtimeConfiguration: String

    @Option(help: "Exact absolute evaluation root from runtime.json.")
    var evaluationRoot: String

    @Option(help: "Exact frozen wire model (gpt-5.6-sol).")
    var model: String

    mutating func run() async throws {
      let freeze = try EvaluationJSONFile.decode(
        EvaluationFreezeInputs.self,
        from: URL(fileURLWithPath: freezeInputs)
      )

      let result = try await EvaluationAuthLogin().run(
        EvaluationAuthLoginRequest(
          freeze: freeze,
          runtimeConfigurationPath: runtimeConfiguration,
          evaluationRoot: evaluationRoot,
          wireModel: model
        )
      )

      let exitCode = result.exit.processExitCode
      guard exitCode == ExitCode.success.rawValue else {
        throw ExitCode(exitCode)
      }
    }
  }

  struct Worker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run exactly one isolated attempt.")

    @Option(help: "Absolute path to a controller-minted, manifest-bound worker invocation.")
    var invocation: String

    @Flag(help: "Read the ephemeral 32-byte sealed-output key from standard input.")
    var sealedOutputKeyStdin = false

    mutating func run() async throws {
      switch try EvaluationWorkerInput.decode(from: URL(fileURLWithPath: invocation)) {
      case .legacy(let authorized):
        let key =
          sealedOutputKeyStdin
          ? FileHandle.standardInput.readDataToEndOfFile()
          : nil
        let attemptID = try await EvaluationWorker().run(
          invocation: authorized,
          sealedOutputKey: key
        )
        print(attemptID)
      case .scheduledLearning(let authorized):
        guard sealedOutputKeyStdin == false else {
          throw ValidationError("scheduled-learning-v1 does not accept a sealed-output key")
        }
        print(try await EvaluationWorker().run(invocation: authorized))
      }
    }
  }

  struct LearningCall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "learning-call",
      abstract: "Run one isolated scheduled-learning evaluator or reflector call."
    )

    @Option(help: "Absolute path to one manifest-bound learning-call request.")
    var request: String

    mutating func run() async throws {
      let value = try EvaluationLearningCallRequest.load(
        from: URL(fileURLWithPath: request)
      )
      let result = try await EvaluationLearningCall().run(request: value)
      print(result.operationID)
    }
  }

  struct CanaryProcess: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "canary-process",
      abstract: "Run one clean/non-empty canary pair in a single lock-owning process."
    )

    @Option(help: "Absolute path to a controller-minted, manifest-bound canary invocation.")
    var invocation: String

    mutating func run() async throws {
      let url = URL(fileURLWithPath: invocation)
      let authorized = try EvaluationJSONFile.decode(EvaluationWorkerInvocation.self, from: url)
      let results = try await EvaluationWorker().runCanaryProcess(invocation: authorized)
      print(results.joined(separator: ","))
    }
  }

  struct InspectPolicy: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "inspect-policy",
      abstract: "Compute the frozen evaluation policy version without credentials or model calls."
    )

    @Option(help: "Absolute path to the frozen runtime.json file.")
    var runtimeConfiguration: String

    mutating func run() throws {
      let runtime = try EvaluationRuntimeConfiguration.load(
        from: URL(fileURLWithPath: runtimeConfiguration)
      )
      print(EvaluationPolicyInspector.policyVersion(for: runtime))
    }
  }
}
