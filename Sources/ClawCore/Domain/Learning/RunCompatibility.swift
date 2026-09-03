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

/// The evaluator's own half of a run's compatibility surface, stamped when the evaluation is
/// committed. Held apart from `RunSurface`, which froze at the run's pickup: these four values
/// describe the call that judged the run, not the call the run itself made.
public struct EvaluatorSurface: Sendable, Equatable {
  /// The route that actually served the evaluation, which is not necessarily the one it was
  /// authorized to start on.
  public let route: String
  public let promptVersion: Int
  public let schemaVersion: Int
  public let rubricVersion: Int

  public init(route: String, promptVersion: Int, schemaVersion: Int, rubricVersion: Int) {
    self.route = route
    self.promptVersion = promptVersion
    self.schemaVersion = schemaVersion
    self.rubricVersion = rubricVersion
  }
}

extension RunCompatibility {
  /// Frozen into every compatibility digest. A change to the field list below must change this
  /// value too, so verdicts frozen under the old list keep answering the question they were
  /// computed for.
  private static let canonicalPrefix = "run-compatibility/v1"
  /// What an absent field reads as. A digest that simply skipped one would collide with one whose
  /// neighbouring field held the empty string.
  private static let absentField = "\u{0}"
  /// The algorithm reserves a slot for an adapter id/version and a task-input schema version.
  /// `scheduled-learning/v1` has neither, and the canonical `none` keeps the slot positionally
  /// present — so the day one arrives it opens a new window instead of colliding with every
  /// verdict reached without it.
  private static let adapterSlot = "none"

  /// Every input two runs must match on before their verdicts may be counted as evidence about the
  /// same question, in the order the accepted algorithm lists them.
  ///
  /// Deliberately absent, because they are provenance rather than compatibility: run ids,
  /// timestamps, the task input, the final output, the model-visible carrier bytes and the evidence
  /// digests. `stableDigest` is hashed rather than `effectiveDigest` — a trial run answers against a
  /// candidate set and never enters a stable evidence window at all.
  public func digest(
    binding: RunLearningBinding,
    terminalRoute: String?,
    evaluator: EvaluatorSurface
  ) -> CompatibilityDigest {
    let fields = [
      Self.canonicalPrefix,
      String(jobId),
      String(epoch.value),
      binding.jobDefinitionDigest.rawValue,
      binding.stableDigest.rawValue,
      evidenceSchemaVersion ?? Self.absentField,
      classifierVersion ?? Self.absentField,
      String(evaluator.promptVersion),
      String(evaluator.schemaVersion),
      String(evaluator.rubricVersion),
      contextSchemaVersion,
      toolCatalogDigest,
      policyVersion,
      skillSetDigest,
      configuredRoute,
      terminalRoute ?? Self.absentField,
      evaluator.route,
      Self.adapterSlot,
    ]
    return CompatibilityDigest(rawValue: SHA256Digest.hex(fields.joined(separator: ":")))
  }
}
