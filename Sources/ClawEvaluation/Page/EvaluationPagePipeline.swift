import ClawAgent
import ClawCore
import ClawSubprocess
import Foundation

struct EvaluationPagePipelineResult: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let outcome: EvaluationPageTerminalClassification
  package let incomplete: Bool
  package let stopReason: String?
  package let canarySummary: EvaluationControllerSummary
  package let summary: EvaluationControllerSummary
  package let developmentGateSHA256: String?
  package let promotionReceiptSHA256: String?
  package let regressionGateSHA256: String?
  package let regressionJointUnsealReceiptSHA256: String?
  package let sealedGateSHA256: String?
  package let journalSHA256: String
  package let lifecycleReceiptSHA256: String?
  package let jointUnsealReceiptSHA256: String?
  package let synthesisRejectionReportSHA256: String?

  package init(
    outcome: EvaluationPageTerminalClassification,
    incomplete: Bool,
    stopReason: String?,
    canarySummary: EvaluationControllerSummary,
    summary: EvaluationControllerSummary,
    developmentGateSHA256: String?,
    promotionReceiptSHA256: String?,
    regressionGateSHA256: String?,
    regressionJointUnsealReceiptSHA256: String?,
    sealedGateSHA256: String?,
    journalSHA256: String,
    lifecycleReceiptSHA256: String?,
    jointUnsealReceiptSHA256: String?,
    synthesisRejectionReportSHA256: String?
  ) {
    schemaVersion = PageEvaluationContract.schemaVersion
    self.outcome = outcome
    self.incomplete = incomplete
    self.stopReason = stopReason
    self.canarySummary = canarySummary
    self.summary = summary
    self.developmentGateSHA256 = developmentGateSHA256
    self.promotionReceiptSHA256 = promotionReceiptSHA256
    self.regressionGateSHA256 = regressionGateSHA256
    self.regressionJointUnsealReceiptSHA256 = regressionJointUnsealReceiptSHA256
    self.sealedGateSHA256 = sealedGateSHA256
    self.journalSHA256 = journalSHA256
    self.lifecycleReceiptSHA256 = lifecycleReceiptSHA256
    self.jointUnsealReceiptSHA256 = jointUnsealReceiptSHA256
    self.synthesisRejectionReportSHA256 = synthesisRejectionReportSHA256
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case outcome, incomplete
    case stopReason = "stop_reason"
    case canarySummary = "canary_summary"
    case summary
    case developmentGateSHA256 = "development_gate_sha256"
    case promotionReceiptSHA256 = "promotion_receipt_sha256"
    case regressionGateSHA256 = "regression_gate_sha256"
    case regressionJointUnsealReceiptSHA256 = "regression_joint_unseal_receipt_sha256"
    case sealedGateSHA256 = "sealed_gate_sha256"
    case journalSHA256 = "journal_sha256"
    case lifecycleReceiptSHA256 = "lifecycle_receipt_sha256"
    case jointUnsealReceiptSHA256 = "joint_unseal_receipt_sha256"
    case synthesisRejectionReportSHA256 = "synthesis_rejection_report_sha256"
  }
}

protocol EvaluationProtectedArtifactRunning: Sendable {
  func run(
    relativeExecutablePath: String,
    arguments: [String],
    protectedOutputURLs: [URL],
    freeze: EvaluationFreezeContext,
    captureLimit: Int
  ) async throws -> Data
}

struct EvaluationConformanceReceiptBinding: Sendable, Equatable {
  let passed: Int
  let total: Int
}

struct EvaluationProtectedArtifactRunner: EvaluationProtectedArtifactRunning {
  package init() {}

  package func run(
    relativeExecutablePath: String,
    arguments: [String],
    protectedOutputURLs: [URL],
    freeze: EvaluationFreezeContext,
    captureLimit: Int = 2 * 1_024 * 1_024
  ) async throws -> Data {
    guard
      let record = freeze.manifest.artifact(relativePath: relativeExecutablePath),
      record.path == relativeExecutablePath
    else {
      throw EvaluationPagePipelineError.missingProtectedArtifact(relativeExecutablePath)
    }
    let root = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true).standardizedFileURL
    let executable = root.appendingPathComponent(record.path).standardizedFileURL
    try EvaluationProtectedClosure.verify(freeze)
    try EvaluationProtectedOutputGuard.prepare(outputs: protectedOutputURLs)
    let result = await SwiftSubprocessRunner(executablePath: executable.path).run(
      SubprocessCommand(
        arguments: arguments,
        timeout: .seconds(60),
        captureLimit: captureLimit,
        teardownGracePeriod: .seconds(2)
      )
    )
    try EvaluationProtectedClosure.verify(freeze)
    try EvaluationProtectedOutputGuard.validatePublished(protectedOutputURLs)
    guard case .exited(0) = result.termination, result.stdout.truncated == false else {
      throw EvaluationPagePipelineError.protectedArtifactFailed(record.path)
    }
    return result.stdout.bytes
  }
}

enum EvaluationProtectedOutputGuard {
  static func prepare(outputs: [URL]) throws {
    for output in outputs {
      guard output.path.hasPrefix("/") else {
        throw EvaluationPagePipelineError.invalidManifestContract
      }
      try EvaluationPathSecurity.rejectSymlinkComponents(
        in: [output.deletingLastPathComponent(), output]
      )
      guard FileManager.default.fileExists(atPath: output.path) == false else {
        throw EvaluationPagePipelineError.protectedOutputExists(output.lastPathComponent)
      }
    }
    guard Set(outputs.map(\.standardizedFileURL)).count == outputs.count else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
  }

  static func validatePublished(_ outputs: [URL]) throws {
    for output in outputs {
      do {
        try EvaluationPathSecurity.rejectSymlinkComponents(
          in: [output.deletingLastPathComponent(), output]
        )
        try EvaluationPathSecurity.requireRegularSingleLinkFile(at: output)
      } catch {
        throw EvaluationPagePipelineError.protectedOutputMissing(output.lastPathComponent)
      }
    }
  }
}

enum EvaluationProtectedClosure {
  static func verify(_ freeze: EvaluationFreezeContext) throws {
    let root = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true).standardizedFileURL
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [root])
    guard
      freeze.manifest.protectedArtifacts.isEmpty == false,
      Set(freeze.manifest.protectedArtifacts.map(\.path)).count
        == freeze.manifest.protectedArtifacts.count
    else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    for artifact in freeze.manifest.protectedArtifacts.sorted(by: { $0.path < $1.path }) {
      do {
        _ = try EvaluationManifestBoundArtifactReader.read(
          relativePath: artifact.path,
          expectedByteCount: artifact.bytes,
          expectedSHA256: artifact.sha256,
          repositoryRoot: root
        )
      } catch EvaluationManifestBoundArtifactError.invalidRelativePath(_) {
        throw EvaluationPagePipelineError.invalidManifestContract
      } catch {
        throw EvaluationPagePipelineError.protectedArtifactChanged(artifact.path)
      }
    }
  }
}

enum EvaluationPagePipelineError: Error, Sendable, Equatable {
  case invalidBatch(String)
  case carrierFailure(String)
  case safetyFailure(String)
  case taskSpecificFailure(String)
  case incompleteBatch(String)
  case invalidManifestContract
  case canaryEvidenceMissing
  case invalidRunOrder
  case missingProtectedArtifact(String)
  case protectedArtifactChanged(String)
  case protectedArtifactFailed(String)
  case protectedOutputExists(String)
  case protectedOutputMissing(String)
  case stageGateFailed(String)
  case stageGateReceiptInvalid(String)
  case synthesisFailed(String)
  case promotionFailed
  case resultUnavailable(String)
  case recordConstructionFailed(String)
  case restartBoundaryFailed
}

enum EvaluationPageTerminalClassification: String, Codable, Sendable, Equatable {
  case invalidBatch = "invalid_batch"
  case carrierFailure = "carrier_failure"
  case safetyFailure = "safety_failure"
  case pageTaskSpecificFailure = "page_task_specific_failure"
  case incompleteBatch = "incomplete_batch"

  var isIncomplete: Bool { self == .incompleteBatch }
}

extension EvaluationController {
  static let pageRootPath = "experiments/scheduled-task-learning/page-change"

  struct PagePipelinePaths {
    let root: URL
    let configurations: URL
    let results: URL
    let receipts: URL
    let conformance: URL
    let canarySummary: URL
    let canaryLifecycle: URL
    let canaryProcessA: URL
    let canaryProcessB: URL
    let developmentRecords: URL
    let runOrder: URL
    let developmentRuns: URL
    let developmentBundle: URL
    let developmentGate: URL
    let synthesisInput: URL
    let synthesisTranscript: URL
    let synthesisCandidate: URL
    let lintReport: URL
    let promotedTemporary: URL
    let promotionReceipt: URL
    let regressionRecords: URL
    let regressionJointUnsealReceipt: URL
    let regressionGate: URL
    let lifecycleReceipt: URL
    let sealedRecords: URL
    let sealedGate: URL
    let jointUnsealReceipt: URL
    let synthesisRejectionReport: URL
    let summary: URL
    let result: URL

    init(evaluationRoot: URL) {
      root = evaluationRoot.appendingPathComponent("pipeline", isDirectory: true)
      configurations = root.appendingPathComponent("configurations", isDirectory: true)
      results = evaluationRoot.appendingPathComponent(PageEvaluationContract.resultsDirectoryName)
      receipts = evaluationRoot.appendingPathComponent("receipts", isDirectory: true)
      conformance = receipts.appendingPathComponent("page-conformance.json")
      canarySummary = receipts.appendingPathComponent("canary-summary.json")
      canaryLifecycle = receipts.appendingPathComponent("canary-lifecycle.json")
      canaryProcessA = configurations.appendingPathComponent("canary-process-a.json")
      canaryProcessB = configurations.appendingPathComponent("canary-process-b.json")
      developmentRecords = root.appendingPathComponent("development-records.json")
      runOrder = root.appendingPathComponent("run-order.json")
      developmentRuns = root.appendingPathComponent("development-runs.json")
      developmentBundle = root.appendingPathComponent("development-bundle.json")
      developmentGate = receipts.appendingPathComponent("development-gate.json")
      synthesisInput = root.appendingPathComponent("synthesis-input.json")
      synthesisTranscript = root.appendingPathComponent("synthesis-transcript.json")
      synthesisCandidate = root.appendingPathComponent("synthesis-candidate.json")
      lintReport = root.appendingPathComponent("lesson-lint-report.json")
      promotedTemporary = root.appendingPathComponent("promoted-lesson-set.json")
      promotionReceipt = receipts.appendingPathComponent("promotion.json")
      regressionRecords = root.appendingPathComponent("regression-records.json")
      regressionJointUnsealReceipt = receipts.appendingPathComponent(
        "regression-joint-unseal.json"
      )
      regressionGate = receipts.appendingPathComponent("regression-gate.json")
      lifecycleReceipt = receipts.appendingPathComponent("page-restart-lifecycle.json")
      sealedRecords = root.appendingPathComponent("sealed-records.json")
      sealedGate = receipts.appendingPathComponent("sealed-gate.json")
      jointUnsealReceipt = receipts.appendingPathComponent("sealed-joint-unseal.json")
      synthesisRejectionReport = receipts.appendingPathComponent(
        "lesson-synthesis-rejection.json"
      )
      summary = receipts.appendingPathComponent("page-summary.json")
      result = receipts.appendingPathComponent("page-pipeline-result.json")
    }
  }
}
