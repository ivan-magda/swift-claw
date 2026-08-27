import ClawCore
import Foundation

extension EvaluationPageExperiment {
  func prepare(_ paths: EvaluationController.PagePipelinePaths) throws {
    for directory in [paths.root, paths.configurations, paths.results, paths.receipts] {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)
    }
  }

  func unsealed(
    _ accepted: [EvaluationController.AcceptedAttempt]
  ) throws -> [EvaluationRecordedAttempt] {
    try accepted.map { item in
      guard case .result(let result) = item.payload else {
        throw EvaluationPagePipelineError.recordConstructionFailed("unexpected_sealed_result")
      }

      let configuration = try EvaluationJSONFile.decode(
        EvaluationAttemptConfiguration.self,
        from: URL(fileURLWithPath: item.actualConfigurationPath)
      )
      let data = try EvaluationPathSecurity.readRegularSingleLinkFile(
        at: configuration.resultURL
      )

      return EvaluationRecordedAttempt(
        result: result,
        resultOrEnvelopeSHA256: SHA256Digest.hex(data),
        originalAttemptEvidenceSHA256: item.originalAttemptEvidenceSHA256
      )
    }
  }

  func sealedReceipt(
    in accepted: [EvaluationController.AcceptedAttempt],
    orderKey: String
  ) throws -> EvaluationSealedAttemptReceipt {
    guard
      let item = accepted.first(where: { accepted in
        switch accepted.payload {
        case .sealed(let receipt): receipt.frozenOrderKey == orderKey
        case .result: false
        }
      }),
      case .sealed(let receipt) = item.payload
    else {
      throw EvaluationPagePipelineError.restartBoundaryFailed
    }
    return receipt
  }

  func protectedPath(_ relative: String, freeze: EvaluationFreezeContext) throws -> String {
    guard let record = freeze.manifest.artifact(relativePath: relative) else {
      throw EvaluationPagePipelineError.missingProtectedArtifact(relative)
    }

    do {
      return try EvaluationManifestBoundArtifactReader.read(
        relativePath: record.path,
        expectedByteCount: record.bytes,
        expectedSHA256: record.sha256,
        repositoryRoot: URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
      ).url.path
    } catch {
      throw EvaluationPagePipelineError.protectedArtifactChanged(relative)
    }
  }
}
