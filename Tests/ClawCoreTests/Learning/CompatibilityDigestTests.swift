import ClawCore
import Foundation
import Testing

/// Two runs are comparable evidence about the same question only while every input the accepted
/// algorithm fixes is unchanged. A digest that dropped one would pool non-comparable runs into a
/// single reflection window — the unsoundness the whole compatibility rule exists to prevent — and
/// a digest that added a per-run value would split every window down to one run and prevent
/// reflection entirely.
@Suite struct CompatibilityDigestTests {
  @Test func everyCompatibilityInputChangesTheDigest() throws {
    // given — the baseline, then one variant per input the algorithm fixes, each differing in
    // exactly one of them
    let baseline = digest()
    let variants = [
      digest(jobId: 99),
      digest(epoch: LearningEpoch(7)),
      digest(jobDefinitionDigest: "job-definition-after-a-prompt-edit"),
      digest(stableDigest: "stable-set-after-a-promotion"),
      digest(evidenceSchemaVersion: "evidence/v2"),
      digest(classifierVersion: "classifier-v2"),
      digest(contextSchemaVersion: "ctx-2"),
      digest(toolCatalogDigest: "tools-v2"),
      digest(policyVersion: "pv17"),
      digest(skillSetDigest: "skills-v2"),
      digest(configuredRoute: "openai-compatible/other-primary"),
      digest(terminalRoute: "openai-compatible/served-by-the-fallback"),
      digest(terminalRoute: nil),
      digest(evaluatorRoute: "openai-compatible/other-evaluator"),
      digest(evaluatorPromptVersion: 2),
      digest(evaluatorSchemaVersion: 2),
      digest(evaluatorRubricVersion: 2),
    ]

    // when
    let all = [baseline] + variants

    // then — every one is distinct: a dropped input would collide its variant with the baseline
    #expect(Set(all).count == all.count)
  }

  @Test func provenanceOnlyValuesLeaveTheDigestAlone() throws {
    // given — the same surface seen through a different run, occurrence and effective set
    let baseline = digest()

    // when
    let anotherRun = digest(
      runId: 4_242,
      effectiveDigest: "the-open-trials-candidate-set",
      occurrenceAt: Date(timeIntervalSince1970: 1_799_999_999)
    )

    // then — hashing any of these would give every run its own window and stop reflection dead
    #expect(anotherRun == baseline)
  }
}

// MARK: - Fixture

// swiftlint:disable:next function_default_parameter_at_end
private func digest(
  runId: Int64 = 41,
  jobId: Int64 = 10,
  epoch: LearningEpoch = LearningEpoch(1),
  jobDefinitionDigest: String = "job-definition-v1",
  stableDigest: String = "stable-set-v1",
  effectiveDigest: String = "stable-set-v1",
  occurrenceAt: Date = Date(timeIntervalSince1970: 1_782_000_600),
  evidenceSchemaVersion: String? = "evidence/v1",
  classifierVersion: String? = "classifier-v1",
  contextSchemaVersion: String = "ctx-1",
  toolCatalogDigest: String = "tools-v1",
  policyVersion: String = "pv16",
  skillSetDigest: String = "skills-v1",
  configuredRoute: String = "openai-compatible/primary-model",
  terminalRoute: String? = "openai-compatible/primary-model",
  evaluatorRoute: String = "openai-compatible/evaluator-model",
  evaluatorPromptVersion: Int = 1,
  evaluatorSchemaVersion: Int = 1,
  evaluatorRubricVersion: Int = 1
) -> CompatibilityDigest {
  let compatibility = RunCompatibility(
    runId: runId,
    jobId: jobId,
    epoch: epoch,
    contextSchemaVersion: contextSchemaVersion,
    toolCatalogDigest: toolCatalogDigest,
    policyVersion: policyVersion,
    skillSetDigest: skillSetDigest,
    configuredRoute: configuredRoute,
    evidenceSchemaVersion: evidenceSchemaVersion,
    classifierVersion: classifierVersion
  )
  let binding = RunLearningBinding(
    runId: runId,
    jobId: jobId,
    occurrenceAt: occurrenceAt,
    fireKind: .scheduledOccurrence,
    jobDefinitionDigest: JobDefinitionDigest(rawValue: jobDefinitionDigest),
    epoch: epoch,
    stableDigest: LessonSetDigest(rawValue: stableDigest),
    effectiveDigest: LessonSetDigest(rawValue: effectiveDigest),
    trialId: nil,
    trialGeneration: nil
  )
  return compatibility.digest(
    binding: binding,
    terminalRoute: terminalRoute,
    evaluator: EvaluatorSurface(
      route: evaluatorRoute,
      promptVersion: evaluatorPromptVersion,
      schemaVersion: evaluatorSchemaVersion,
      rubricVersion: evaluatorRubricVersion
    )
  )
}
