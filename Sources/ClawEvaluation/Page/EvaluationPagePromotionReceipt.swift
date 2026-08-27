import ClawCore
import Foundation

struct EvaluationPagePromotionReceipt: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let promotionID: String
  let developmentBundleSHA256: String
  let synthesisInputSHA256: String
  let synthesisTranscriptSHA256: String
  let synthesisPromptSHA256: String
  let feedbackGeneratorVersion: String
  let feedbackGeneratorSHA256: String
  let providerReference: String
  let wireModel: String
  let selectedTargetClasses: [String]
  let lintRulesSHA256: String
  let lintReportSHA256: String
  let candidateSHA256: String
  let activeLessonSetSHA256: String
  let activeLessonSetID: String
  let lessonIDs: [String]
  let canonicalByteCount: Int

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case promotionID = "promotion_id"
    case developmentBundleSHA256 = "development_bundle_sha256"
    case synthesisInputSHA256 = "synthesis_input_sha256"
    case synthesisTranscriptSHA256 = "synthesis_transcript_sha256"
    case synthesisPromptSHA256 = "synthesis_prompt_sha256"
    case feedbackGeneratorVersion = "feedback_generator_version"
    case feedbackGeneratorSHA256 = "feedback_generator_sha256"
    case providerReference = "provider_reference"
    case wireModel = "wire_model"
    case selectedTargetClasses = "selected_target_classes"
    case lintRulesSHA256 = "lint_rules_sha256"
    case lintReportSHA256 = "lint_report_sha256"
    case candidateSHA256 = "candidate_sha256"
    case activeLessonSetSHA256 = "active_lesson_set_sha256"
    case activeLessonSetID = "active_lesson_set_id"
    case lessonIDs = "lesson_ids"
    case canonicalByteCount = "canonical_byte_count"
  }

  static func load(from url: URL, expectedSHA256: String? = nil) throws -> Self {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    return try decode(data, expectedSHA256: expectedSHA256)
  }

  static func decode(_ data: Data, expectedSHA256: String? = nil) throws -> Self {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
      let receipt = try? JSONDecoder().decode(Self.self, from: data),
      try EvaluationCanonicalJSON.data(encoding: receipt) == data,
      expectedSHA256.map({ SHA256Digest.hex(data) == $0 }) ?? true,
      receipt.hasValidFrozenShape
    else {
      throw EvaluationPagePromotionReceiptError.invalidReceipt
    }
    return receipt
  }

  func sha256() throws -> String {
    SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: self))
  }

  func validateFrozenProvenance(against freeze: EvaluationFreezeContext) throws {
    guard
      let synthesisPrompt = freeze.manifest.artifact(role: "synthesis", category: "prompts"),
      synthesisPrompt.sha256 == synthesisPromptSHA256,
      freeze.manifest.categories["feedback"]?.sha256 == feedbackGeneratorSHA256,
      feedbackGeneratorVersion == PageEvaluationContract.feedbackGeneratorVersion,
      providerReference == freeze.runtime.providerReference,
      wireModel == freeze.runtime.wireModel
    else {
      throw EvaluationPagePromotionReceiptError.invalidReceipt
    }
  }

  func validatedActiveLessonSetDigest(_ data: Data) throws -> String {
    guard
      SHA256Digest.hex(data) == activeLessonSetSHA256,
      data.count == canonicalByteCount,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["schema_version", "lesson_set_id", "lessons"]),
      CanonicalJSON.integer(object["schema_version"]) == PageEvaluationContract.schemaVersion,
      object["lesson_set_id"] as? String == activeLessonSetID,
      let lessons = object["lessons"] as? [[String: Any]],
      (1...3).contains(lessons.count),
      try EvaluationCanonicalJSON.data(fromJSONObject: object) == data
    else {
      throw EvaluationPagePromotionReceiptError.invalidActiveLessonSet
    }
    var observedLessonIDs: [String] = []
    var observedClasses: [String] = []
    var seenLessonIDs = Set<String>()
    var seenClasses = Set<String>()
    var textScalars = 0
    for lesson in lessons {
      guard
        Set(lesson.keys) == Set(["lesson_id", "target_class", "text"]),
        let lessonID = lesson["lesson_id"] as? String,
        Self.hasContentID(lessonID, prefix: "lesson-"),
        seenLessonIDs.insert(lessonID).inserted,
        let targetClass = lesson["target_class"] as? String,
        PageEvaluationContract.targetClasses.contains(targetClass),
        seenClasses.insert(targetClass).inserted,
        let text = lesson["text"] as? String,
        (1...400).contains(text.unicodeScalars.count)
      else {
        throw EvaluationPagePromotionReceiptError.invalidActiveLessonSet
      }
      observedLessonIDs.append(lessonID)
      observedClasses.append(targetClass)
      textScalars += text.unicodeScalars.count
    }
    guard
      observedLessonIDs == lessonIDs,
      observedClasses == selectedTargetClasses,
      textScalars <= 1_000
    else {
      throw EvaluationPagePromotionReceiptError.invalidActiveLessonSet
    }
    return activeLessonSetSHA256
  }
}

// MARK: - Validation

private extension EvaluationPagePromotionReceipt {
  var hasValidFrozenShape: Bool {
    let digests = [
      developmentBundleSHA256,
      synthesisInputSHA256,
      synthesisTranscriptSHA256,
      synthesisPromptSHA256,
      feedbackGeneratorSHA256,
      lintRulesSHA256,
      lintReportSHA256,
      candidateSHA256,
      activeLessonSetSHA256,
    ]
    return schemaVersion == PageEvaluationContract.schemaVersion
      && digests.allSatisfy(SHA256Digest.isCanonicalHex)
      && feedbackGeneratorVersion == PageEvaluationContract.feedbackGeneratorVersion
      && providerReference == PageEvaluationContract.providerReference
      && wireModel == PageEvaluationContract.wireModel
      && (2...3).contains(selectedTargetClasses.count)
      && Set(selectedTargetClasses).count == selectedTargetClasses.count
      && selectedTargetClasses.allSatisfy(PageEvaluationContract.targetClasses.contains)
      && Self.hasContentID(promotionID, prefix: "promotion-")
      && Self.hasContentID(activeLessonSetID, prefix: "set-")
      && (1...3).contains(lessonIDs.count)
      && Set(lessonIDs).count == lessonIDs.count
      && lessonIDs.allSatisfy { Self.hasContentID($0, prefix: "lesson-") }
      && canonicalByteCount >= 1
  }

  static func hasContentID(_ value: String, prefix: String) -> Bool {
    guard value.hasPrefix(prefix) else {
      return false
    }
    let suffix = value.dropFirst(prefix.count)
    return suffix.count == 12 && suffix.allSatisfy { "0123456789abcdef".contains($0) }
  }
}

enum EvaluationPagePromotionReceiptError: Error, Sendable, Equatable {
  case invalidReceipt
  case invalidActiveLessonSet
}
