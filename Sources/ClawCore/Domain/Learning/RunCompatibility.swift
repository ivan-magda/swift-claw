import Foundation

/// The surface one run actually executed against, captured at pickup while every value in it is
/// still current.
///
/// Skill files, the tool catalog, the prompt materials and the configured route can all change
/// between a run's pickup and the moment its evidence is sealed. A sealer that re-read them would
/// file an old run under the new surface — mixing incompatible runs into one evidence window, or
/// splitting compatible ones apart — so these values are frozen once and only ever read back.
public struct RunSurface: Sendable, Equatable {
  public let contextSchemaVersion: String
  public let toolCatalogDigest: String
  public let policyVersion: String
  public let skillSetDigest: String
  public let configuredRoute: String

  public init(
    contextSchemaVersion: String = RunSurface.currentContextSchemaVersion,
    toolCatalogDigest: String,
    policyVersion: String,
    skillSetDigest: String,
    configuredRoute: String
  ) {
    self.contextSchemaVersion = contextSchemaVersion
    self.toolCatalogDigest = toolCatalogDigest
    self.policyVersion = policyVersion
    self.skillSetDigest = skillSetDigest
    self.configuredRoute = configuredRoute
  }

  /// Derived from the context row set rather than hand-bumped, so adding, removing or renaming a
  /// context row opens a new compatibility window on its own — the failure mode a hand-maintained
  /// constant has is being forgotten.
  public static let currentContextSchemaVersion = String(
    PolicyFingerprint.hash(parts: ContextRowID.allCases.map(\.rawValue)).prefix(16)
  )
}

/// The stored `run_compatibility` row: the pickup-time surface, the job and epoch it belongs to,
/// and the versions the sealer stamped when it froze the run's evidence.
public struct RunCompatibility: Sendable, Equatable {
  public let runId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let contextSchemaVersion: String
  public let toolCatalogDigest: String
  public let policyVersion: String
  public let skillSetDigest: String
  public let configuredRoute: String
  /// Nil until the run is sealed. The evaluator's own route, prompt, schema and rubric versions
  /// join them at evaluator dispatch.
  public let evidenceSchemaVersion: String?
  public let classifierVersion: String?

  public init(
    runId: Int64,
    jobId: Int64,
    epoch: LearningEpoch,
    contextSchemaVersion: String,
    toolCatalogDigest: String,
    policyVersion: String,
    skillSetDigest: String,
    configuredRoute: String,
    evidenceSchemaVersion: String?,
    classifierVersion: String?
  ) {
    self.runId = runId
    self.jobId = jobId
    self.epoch = epoch
    self.contextSchemaVersion = contextSchemaVersion
    self.toolCatalogDigest = toolCatalogDigest
    self.policyVersion = policyVersion
    self.skillSetDigest = skillSetDigest
    self.configuredRoute = configuredRoute
    self.evidenceSchemaVersion = evidenceSchemaVersion
    self.classifierVersion = classifierVersion
  }
}
