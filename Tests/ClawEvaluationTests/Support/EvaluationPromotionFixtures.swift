import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

func makeEvaluationPromotionFixture() throws -> (
  activeLessonData: Data,
  receipt: EvaluationPagePromotionReceipt,
  receiptData: Data
) {
  // Checked output from the frozen page-promotion producer.
  let activeLessonData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "lesson_set_id": "set-11667c50d11a",
    "lessons": [
      [
        "lesson_id": "lesson-bc52fba93e4b",
        "target_class": "noise.volatile_value",
        "text":
          "Treat volatile counters and rotating telemetry as cosmetic when meaning is preserved.",
      ],
      [
        "lesson_id": "lesson-c576af6a8299",
        "target_class": "noise.time_or_build_metadata",
        "text":
          "Ignore generated timestamp and build metadata when user-facing state is unchanged.",
      ],
      [
        "lesson_id": "lesson-2b7ccc3beccf",
        "target_class": "noise.structure_or_order",
        "text":
          "Classify layout or reorder changes as cosmetic when items and meaning are preserved.",
      ],
    ],
    "schema_version": 1,
  ])
  let receiptData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "active_lesson_set_id": "set-11667c50d11a",
    "active_lesson_set_sha256":
      "0cfc4e28afc4c45bde8595fc1007cb183a1514c776728d67bb703f2b24e19182",
    "candidate_sha256":
      "11667c50d11a7b524e4a21b34ed3143381dd34f3a40569e3787ae0a8d7e36e2f",
    "canonical_byte_count": 583,
    "development_bundle_sha256":
      "e2704bf5096bd0dc22a8780de222e2c1b58252b48bf2211685cd9fc91dcc0869",
    "feedback_generator_sha256":
      "e40309218465bdce4149c720bb5e9dcb40f719422bf08e8e5ac58c35ed03ea22",
    "feedback_generator_version": PageEvaluationContract.feedbackGeneratorVersion,
    "lesson_ids": [
      "lesson-bc52fba93e4b",
      "lesson-c576af6a8299",
      "lesson-2b7ccc3beccf",
    ],
    "lint_report_sha256":
      "f20d4a24e506aa17828b47dc79c8bfed1e2fcb1a60f998db58380bcb867290eb",
    "lint_rules_sha256":
      "a564f68b9b63e5b2bc0e4f2126d058c0e837a884edd52cbab73c895dfe03922e",
    "promotion_id": "promotion-f0f7610fd975",
    "provider_reference": PageEvaluationContract.providerReference,
    "schema_version": PageEvaluationContract.schemaVersion,
    "selected_target_classes": [
      "noise.volatile_value",
      "noise.time_or_build_metadata",
      "noise.structure_or_order",
    ],
    "synthesis_input_sha256":
      "06836ac77cb60896b54546c8ba7752ed09bb88fc74037418af9779882f08c972",
    "synthesis_prompt_sha256":
      "7ba9ff2beb1608bd13346f99322c1b28efbbea04d3e8d399deb7ed0c7e8457ca",
    "synthesis_transcript_sha256":
      "826a6c1a58dad6862f5a83149ac2edfe16ef024b73d600cb970df75f75f7b048",
    "wire_model": PageEvaluationContract.wireModel,
  ])
  let receipt = try EvaluationPagePromotionReceipt.decode(
    receiptData,
    expectedSHA256: "028fd248a46455b24276c578699da180ee236b0a65a7641a7e5aa6991775909d"
  )
  _ = try receipt.validatedActiveLessonSetDigest(activeLessonData)
  return (
    activeLessonData,
    receipt,
    receiptData
  )
}
