import ClawCore
import ClawSecrets
import Crypto
import Foundation

/// Non-semantic controller receipt for a sealed attempt. The worker never writes the decoded model
/// output until every sealed condition and the restart boundary have completed.
struct EvaluationSealedAttemptReceipt: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let attemptID: String
  package let fixtureID: String
  package let condition: EvaluationCondition
  package let manifestSHA256: String
  package let processUUID: UUID
  package let processID: Int32
  package let lockAcquisitionID: UUID
  package let conversationID: String
  package let frozenOrderIndex: Int
  package let frozenOrderKey: String
  package let lessonSetDigest: String
  package let lessonSetID: String
  package let lessonIDs: [String]
  package let carrierReceiptSHA256: String
  package let workspaceWasEmptyAtStart: Bool
  package let inputWasRegenerated: Bool
  package let envelopePath: String
  package let envelopeSHA256: String
  package let plaintextSHA256: String
  package let outcome: EvaluationAttemptOutcome
  package let criticalCode: String?
  package let responsesRequests: [EvaluationResponsesSend]
  package let provenNotStartedResponsesSends: Int
  package let credentialHTTPCalls: Int
  package let fileReads: Int
  package let usage: [EvaluationUsageRecord]
  package let accountedTokens: Int
  package let replacementDisposition: EvaluationReplacementDisposition

  package init(
    result: EvaluationAttemptResult,
    lockAcquisitionID: UUID,
    envelopePath: String,
    envelope: Data,
    plaintext: Data
  ) {
    schemaVersion = PageEvaluationContract.schemaVersion
    attemptID = result.attemptID
    fixtureID = result.fixtureID
    condition = result.condition
    manifestSHA256 = result.manifestSHA256
    processUUID = result.processUUID
    processID = result.processID
    self.lockAcquisitionID = lockAcquisitionID
    conversationID = result.conversationID
    frozenOrderIndex = result.frozenOrderIndex
    frozenOrderKey = result.frozenOrderKey
    lessonSetDigest = result.lessonSetDigest
    lessonSetID = result.lessonSetID
    lessonIDs = result.lessonIDs
    carrierReceiptSHA256 = result.carrierReceiptSHA256
    workspaceWasEmptyAtStart = result.workspace.workspaceWasEmptyAtStart
    inputWasRegenerated = result.workspace.inputWasRegenerated
    self.envelopePath = envelopePath
    envelopeSHA256 = SHA256Digest.hex(envelope)
    plaintextSHA256 = SHA256Digest.hex(plaintext)
    outcome = result.outcome
    criticalCode = result.criticalCode
    responsesRequests = result.http.responsesSends
    provenNotStartedResponsesSends = result.http.provenNotStartedResponsesSends
    credentialHTTPCalls = result.http.credentialHTTPCalls
    fileReads = EvaluationToolContract.observedFileReads(
      in: result.tools,
      expectedPath: result.stage == EvaluationPageStage.synthesis.rawValue
        ? PageEvaluationContract.synthesisInputFileName : PageEvaluationContract.inputFileName
    )
    usage = result.usage
    accountedTokens = result.accountedTokens
    replacementDisposition = result.replacementDisposition
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case attemptID = "attempt_id"
    case fixtureID = "fixture_id"
    case condition
    case manifestSHA256 = "manifest_sha256"
    case processUUID = "process_uuid"
    case processID = "process_id"
    case lockAcquisitionID = "lock_acquisition_id"
    case conversationID = "conversation_id"
    case frozenOrderIndex = "frozen_order_index"
    case frozenOrderKey = "frozen_order_key"
    case lessonSetDigest = "lesson_set_digest"
    case lessonSetID = "lesson_set_id"
    case lessonIDs = "lesson_ids"
    case carrierReceiptSHA256 = "carrier_receipt_sha256"
    case workspaceWasEmptyAtStart = "workspace_was_empty_at_start"
    case inputWasRegenerated = "input_was_regenerated"
    case envelopePath = "envelope_path"
    case envelopeSHA256 = "envelope_sha256"
    case plaintextSHA256 = "plaintext_sha256"
    case outcome
    case criticalCode = "critical_code"
    case responsesRequests = "responses_requests"
    case provenNotStartedResponsesSends = "proven_not_started_responses_sends"
    case credentialHTTPCalls = "credential_http_calls"
    case fileReads = "file_reads"
    case usage
    case accountedTokens = "accounted_tokens"
    case replacementDisposition = "replacement_disposition"
  }

  package var responsesSends: Int { responsesRequests.count }
}

struct EvaluationJointUnsealReceipt: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let manifestSHA256: String
  package let conditions: [String]
  package let attemptIDs: [String]
  package let envelopeSHA256s: [String]
  package let plaintextSHA256s: [String]
  package let supersededAttemptIDs: [String]
  package let supersededEnvelopeSHA256s: [String]
  package let supersededPlaintextSHA256s: [String]

  package init(
    manifestSHA256: String,
    conditions: [String],
    attemptIDs: [String],
    envelopeSHA256s: [String],
    plaintextSHA256s: [String],
    supersededAttemptIDs: [String],
    supersededEnvelopeSHA256s: [String],
    supersededPlaintextSHA256s: [String]
  ) {
    schemaVersion = PageEvaluationContract.schemaVersion
    self.manifestSHA256 = manifestSHA256
    self.conditions = conditions
    self.attemptIDs = attemptIDs
    self.envelopeSHA256s = envelopeSHA256s
    self.plaintextSHA256s = plaintextSHA256s
    self.supersededAttemptIDs = supersededAttemptIDs
    self.supersededEnvelopeSHA256s = supersededEnvelopeSHA256s
    self.supersededPlaintextSHA256s = supersededPlaintextSHA256s
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case manifestSHA256 = "manifest_sha256"
    case conditions
    case attemptIDs = "attempt_ids"
    case envelopeSHA256s = "envelope_sha256s"
    case plaintextSHA256s = "plaintext_sha256s"
    case supersededAttemptIDs = "superseded_attempt_ids"
    case supersededEnvelopeSHA256s = "superseded_envelope_sha256s"
    case supersededPlaintextSHA256s = "superseded_plaintext_sha256s"
  }
}

struct EvaluationPageRestartLifecycleReceipt: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let publisherAttemptID: String
  let publisherFrozenOrderKey: String
  let publisherProcessUUID: UUID
  let publisherLockAcquisitionID: UUID
  let firstReloadAttemptID: String
  let firstReloadFrozenOrderKey: String
  let firstReloadProcessUUID: UUID
  let firstReloadLockAcquisitionID: UUID
  let durableLessonDigest: String
  let durableLessonSetID: String
  let durableLessonIDs: [String]
  let workspaceWasEmpty: Bool
  let inputWasRegenerated: Bool
  let lockWasReleased: Bool
  let lockWasReacquired: Bool

  init(
    publisher: EvaluationSealedAttemptReceipt,
    firstReload: EvaluationSealedAttemptReceipt,
    publisherSlot: EvaluationPageTaskSlot,
    firstReloadSlot: EvaluationPageTaskSlot,
    lockWasReleased: Bool
  ) throws {
    guard
      publisherSlot.stage == EvaluationPageStage.sealedPreRestart.rawValue,
      publisherSlot.condition == EvaluationCondition.lessonConditioned.runOrderValue,
      publisherSlot.lessonSource == .artifact,
      firstReloadSlot.stage == EvaluationPageStage.sealedPostRestart.rawValue,
      firstReloadSlot.condition == EvaluationCondition.postRestartLessonConditioned.runOrderValue,
      firstReloadSlot.lessonSource == .durableActive,
      Self.receipt(publisher, matches: publisherSlot),
      Self.receipt(firstReload, matches: firstReloadSlot),
      publisher.processUUID != firstReload.processUUID,
      publisher.lockAcquisitionID != firstReload.lockAcquisitionID,
      publisher.lessonSetDigest == firstReload.lessonSetDigest,
      publisher.lessonSetID == firstReload.lessonSetID,
      publisher.lessonIDs == firstReload.lessonIDs,
      publisher.lessonIDs.isEmpty == false,
      lockWasReleased,
      firstReload.workspaceWasEmptyAtStart,
      firstReload.inputWasRegenerated
    else { throw EvaluationPagePipelineError.restartBoundaryFailed }
    schemaVersion = PageEvaluationContract.schemaVersion
    publisherAttemptID = publisher.attemptID
    publisherFrozenOrderKey = publisher.frozenOrderKey
    publisherProcessUUID = publisher.processUUID
    publisherLockAcquisitionID = publisher.lockAcquisitionID
    firstReloadAttemptID = firstReload.attemptID
    firstReloadFrozenOrderKey = firstReload.frozenOrderKey
    firstReloadProcessUUID = firstReload.processUUID
    firstReloadLockAcquisitionID = firstReload.lockAcquisitionID
    durableLessonDigest = firstReload.lessonSetDigest
    durableLessonSetID = firstReload.lessonSetID
    durableLessonIDs = firstReload.lessonIDs
    workspaceWasEmpty = firstReload.workspaceWasEmptyAtStart
    inputWasRegenerated = firstReload.inputWasRegenerated
    self.lockWasReleased = lockWasReleased
    lockWasReacquired = true
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case publisherAttemptID = "publisher_attempt_id"
    case publisherFrozenOrderKey = "publisher_frozen_order_key"
    case publisherProcessUUID = "publisher_process_uuid"
    case publisherLockAcquisitionID = "publisher_lock_acquisition_id"
    case firstReloadAttemptID = "first_reload_attempt_id"
    case firstReloadFrozenOrderKey = "first_reload_frozen_order_key"
    case firstReloadProcessUUID = "first_reload_process_uuid"
    case firstReloadLockAcquisitionID = "first_reload_lock_acquisition_id"
    case durableLessonDigest = "durable_lesson_digest"
    case durableLessonSetID = "durable_lesson_set_id"
    case durableLessonIDs = "durable_lesson_ids"
    case workspaceWasEmpty = "workspace_was_empty"
    case inputWasRegenerated = "input_was_regenerated"
    case lockWasReleased = "lock_was_released"
    case lockWasReacquired = "lock_was_reacquired"
  }

  private static func receipt(
    _ receipt: EvaluationSealedAttemptReceipt,
    matches slot: EvaluationPageTaskSlot
  ) -> Bool {
    receipt.frozenOrderIndex == slot.orderIndex
      && receipt.frozenOrderKey == slot.orderKey
      && receipt.fixtureID == slot.fixtureID
      && receipt.condition.runOrderValue == slot.condition
  }
}

enum EvaluationSealedResultStore {
  private struct JointlyUnsealedAttempt: Sendable {
    let result: EvaluationAttemptResult
    let receipt: EvaluationSealedAttemptReceipt
    let configuration: EvaluationAttemptConfiguration
    let accepted: EvaluationController.AcceptedAttempt
  }

  private static let version: UInt8 = 1
  private static let associatedDataPrefix = "swift-claw.scheduled-task-learning.sealed-attempt.v1"

  package static func makeEphemeralKey() -> Data {
    let key = SymmetricKey(size: .bits256)
    return key.withUnsafeBytes { Data($0) }
  }

  package static func envelopeURL(for resultURL: URL) -> URL {
    resultURL.appendingPathExtension("sealed")
  }

  package static func receiptURL(for resultURL: URL) -> URL {
    resultURL.appendingPathExtension("sealed-receipt.json")
  }

  @discardableResult
  package static func seal(
    _ result: EvaluationAttemptResult,
    keyData: Data,
    resultURL: URL
  ) throws -> EvaluationSealedAttemptReceipt {
    try validate(keyData: keyData)
    guard let lockAcquisitionID = result.lockAcquisitionID else {
      throw EvaluationSealedResultError.missingLockEvidence
    }
    guard
      FileManager.default.fileExists(atPath: resultURL.path) == false,
      FileManager.default.fileExists(atPath: envelopeURL(for: resultURL).path) == false,
      FileManager.default.fileExists(atPath: receiptURL(for: resultURL).path) == false
    else {
      throw EvaluationSealedResultError.staleArtifact
    }
    let plaintext = try EvaluationCanonicalJSON.data(encoding: result)
    let key = SymmetricKey(data: keyData)
    let envelope: Data
    do {
      envelope = try codec(
        manifestSHA256: result.manifestSHA256,
        attemptID: result.attemptID
      ).seal(plaintext, key: key)
    } catch {
      throw EvaluationSealedResultError.encryptionFailed
    }
    let envelopeURL = envelopeURL(for: resultURL)
    try writeOpaque(envelope, to: envelopeURL)
    let receipt = EvaluationSealedAttemptReceipt(
      result: result,
      lockAcquisitionID: lockAcquisitionID,
      envelopePath: envelopeURL.path,
      envelope: envelope,
      plaintext: plaintext
    )
    try EvaluationJSONFile.write(receipt, to: receiptURL(for: resultURL))
    return receipt
  }

  package static func unseal(
    receipt: EvaluationSealedAttemptReceipt,
    keyData: Data,
    expectedConfiguration: EvaluationAttemptConfiguration
  ) throws -> EvaluationAttemptResult {
    try validate(keyData: keyData)
    guard
      receipt.schemaVersion == PageEvaluationContract.schemaVersion,
      receipt.attemptID == expectedConfiguration.attemptID,
      receipt.fixtureID == expectedConfiguration.fixtureID,
      receipt.condition == expectedConfiguration.condition,
      receipt.manifestSHA256 == expectedConfiguration.approval.manifestSHA256,
      URL(fileURLWithPath: receipt.envelopePath).standardizedFileURL
        == envelopeURL(for: expectedConfiguration.resultURL).standardizedFileURL
    else {
      throw EvaluationSealedResultError.receiptIdentityMismatch
    }
    let envelopeURL = URL(fileURLWithPath: receipt.envelopePath)
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [envelopeURL.deletingLastPathComponent(), envelopeURL]
    )
    let envelope = try EvaluationPathSecurity.readRegularSingleLinkFile(at: envelopeURL)
    guard
      SHA256Digest.hex(envelope) == receipt.envelopeSHA256,
      let plaintext = try? codec(
        manifestSHA256: receipt.manifestSHA256,
        attemptID: receipt.attemptID
      ).open(envelope, key: SymmetricKey(data: keyData)),
      SHA256Digest.hex(plaintext) == receipt.plaintextSHA256,
      let result = try? JSONDecoder().decode(EvaluationAttemptResult.self, from: plaintext),
      EvaluationController.result(result, matches: expectedConfiguration)
    else {
      throw EvaluationSealedResultError.authenticationFailed
    }
    return result
  }

  static func jointlyUnseal(
    accepted: [EvaluationController.AcceptedAttempt],
    slots: [EvaluationPageTaskSlot],
    keyData: Data,
    manifestSHA256: String,
    receiptURL: URL
  ) throws -> (attempts: [EvaluationRecordedAttempt], receipt: EvaluationJointUnsealReceipt) {
    try validate(keyData: keyData)
    guard
      accepted.count == slots.count,
      Set(slots.map(\.orderKey)).count == slots.count
    else { throw EvaluationSealedResultError.incompleteJointUnseal }
    let acceptedBySlot = try Dictionary(
      uniqueKeysWithValues: accepted.map { item -> (String, EvaluationController.AcceptedAttempt) in
        let original = try EvaluationJSONFile.decode(
          EvaluationAttemptConfiguration.self,
          from: URL(fileURLWithPath: item.originalConfigurationPath)
        )
        return (original.frozenOrderKey, item)
      }
    )
    guard Set(acceptedBySlot.keys) == Set(slots.map(\.orderKey)) else {
      throw EvaluationSealedResultError.incompleteJointUnseal
    }
    var verified: [JointlyUnsealedAttempt] = []
    var superseded:
      [(
        EvaluationAttemptResult,
        EvaluationSealedAttemptReceipt,
        EvaluationAttemptConfiguration
      )] = []
    for slot in slots {
      guard
        let item = acceptedBySlot[slot.orderKey],
        case .sealed(let sealed) = item.payload
      else { throw EvaluationSealedResultError.incompleteJointUnseal }
      let configuration = try EvaluationJSONFile.decode(
        EvaluationAttemptConfiguration.self,
        from: URL(fileURLWithPath: item.actualConfigurationPath)
      )
      guard
        let original = try? EvaluationJSONFile.decode(
          EvaluationAttemptConfiguration.self,
          from: URL(fileURLWithPath: item.originalConfigurationPath)
        ),
        original.frozenOrderKey == slot.orderKey,
        original.frozenOrderIndex == slot.orderIndex,
        original.stage == slot.stage,
        original.split == slot.split,
        original.fixtureID == slot.fixtureID,
        original.replicate == slot.replicate,
        original.condition.runOrderValue == slot.condition,
        configuration.frozenOrderKey == slot.orderKey,
        configuration.frozenOrderIndex == slot.orderIndex,
        configuration.stage == slot.stage,
        configuration.split == slot.split,
        configuration.fixtureID == slot.fixtureID,
        configuration.replicate == slot.replicate,
        configuration.condition.runOrderValue == slot.condition,
        configuration.replacementOrdinal == 0
          || (configuration.replacementOrdinal == 1
            && configuration.replacementOfAttemptID == original.attemptID),
        FileManager.default.fileExists(atPath: configuration.resultURL.path) == false
      else { throw EvaluationSealedResultError.incompleteJointUnseal }
      let result = try unseal(
        receipt: sealed,
        keyData: keyData,
        expectedConfiguration: configuration
      )
      if let originalSealed = item.originalSealedReceipt {
        guard
          configuration.replacementOrdinal == 1,
          item.originalAttemptEvidenceSHA256 == originalSealed.envelopeSHA256,
          originalSealed.replacementDisposition == .eligible,
          FileManager.default.fileExists(atPath: original.resultURL.path) == false
        else { throw EvaluationSealedResultError.incompleteJointUnseal }
        let originalResult = try unseal(
          receipt: originalSealed,
          keyData: keyData,
          expectedConfiguration: original
        )
        superseded.append((originalResult, originalSealed, original))
      } else if configuration.replacementOrdinal == 1 {
        guard item.originalAttemptEvidenceSHA256 != nil else {
          throw EvaluationSealedResultError.incompleteJointUnseal
        }
      }
      verified.append(
        JointlyUnsealedAttempt(
          result: result,
          receipt: sealed,
          configuration: configuration,
          accepted: item
        )
      )
    }
    let receipt = EvaluationJointUnsealReceipt(
      manifestSHA256: manifestSHA256,
      conditions: verified.map { $0.result.condition.runOrderValue },
      attemptIDs: verified.map { $0.result.attemptID },
      envelopeSHA256s: verified.map { $0.receipt.envelopeSHA256 },
      plaintextSHA256s: verified.map { $0.receipt.plaintextSHA256 },
      supersededAttemptIDs: superseded.map { $0.0.attemptID },
      supersededEnvelopeSHA256s: superseded.map { $0.1.envelopeSHA256 },
      supersededPlaintextSHA256s: superseded.map { $0.1.plaintextSHA256 }
    )
    for (result, _, configuration) in superseded {
      try EvaluationJSONFile.write(result, to: configuration.resultURL)
    }
    for attempt in verified {
      try EvaluationJSONFile.write(attempt.result, to: attempt.configuration.resultURL)
    }
    try EvaluationJSONFile.write(receipt, to: receiptURL)
    return (
      verified.map { attempt in
        EvaluationRecordedAttempt(
          result: attempt.result,
          resultOrEnvelopeSHA256: attempt.receipt.envelopeSHA256,
          originalAttemptEvidenceSHA256: attempt.accepted.originalAttemptEvidenceSHA256
        )
      },
      receipt
    )
  }

  private static func validate(keyData: Data) throws {
    guard keyData.count == 32 else { throw EvaluationSealedResultError.invalidKey }
  }

  private static func associatedData(manifestSHA256: String, attemptID: String) -> Data {
    Data("\(associatedDataPrefix):\(manifestSHA256):\(attemptID)".utf8)
  }

  private static func codec(manifestSHA256: String, attemptID: String) -> AESGCMEnvelope {
    AESGCMEnvelope(
      version: version,
      associatedData: associatedData(manifestSHA256: manifestSHA256, attemptID: attemptID)
    )
  }

  private static func writeOpaque(_ data: Data, to url: URL) throws {
    try EvaluationPathSecurity.ensurePrivateDirectory(at: url.deletingLastPathComponent())
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [url])
    try EvaluationDurablePublication.publish(data, to: url)
  }
}

enum EvaluationSealedResultError: Error, Sendable, Equatable {
  case invalidKey
  case missingLockEvidence
  case staleArtifact
  case encryptionFailed
  case receiptIdentityMismatch
  case authenticationFailed
  case incompleteJointUnseal
}
