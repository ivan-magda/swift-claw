import ClawCore
import Foundation
import Testing

@Suite
struct LearningPayloadCompatibilityTests {
  @Test(arguments: rollbackCases)
  private func rollbackPayloadKeepsLegacyAssociatedValueKeys(_ fixture: RollbackCase) throws {
    // given
    let bytes = Data(fixture.json.utf8)

    // when
    let decoded = try JSONDecoder().decode(RollbackTrigger.self, from: bytes)
    let encoded = CanonicalJSON.encode(decoded)

    // then
    #expect(decoded == fixture.trigger)
    #expect(encoded == fixture.json)
  }

  @Test
  func decisionSupportKeepsItsLegacyRunKey() throws {
    // given
    let json = #"{"evaluationRequired":true,"ownerConfirmed":false,"runId":41}"#

    // when
    let decoded = try JSONDecoder().decode(DecisionSupport.self, from: Data(json.utf8))
    let encoded = CanonicalJSON.encode(decoded)

    // then
    #expect(decoded.runID == 41)
    #expect(encoded == json)
  }

  @Test
  func trialIdentityKeepsItsLegacyIdentityKeys() throws {
    // given
    let json = #"{"epoch":{"value":3},"generation":4,"jobId":23,"trialId":17}"#

    // when
    let decoded = try JSONDecoder().decode(LearningTrialIdentity.self, from: Data(json.utf8))
    let encoded = CanonicalJSON.encode(decoded)

    // then
    #expect(
      decoded
        == LearningTrialIdentity(trialID: 17, jobID: 23, epoch: LearningEpoch(3), generation: 4)
    )
    #expect(encoded == json)
  }

  @Test
  func evidencePayloadKeepsItsLegacyMessageAndUsageKeys() throws {
    // given
    let json = """
    {"configuredRoute":"route","contextSchemaVersion":"ctx-1",\
    "effectiveLessonSetDigest":"lessons","finalOutput":"answer",\
    "jobDefinitionDigest":"job","observedCalls":0,"policyVersion":"policy",\
    "proposedCalls":0,"schemaVersion":"evidence/v1","skillSetDigest":"skills",\
    "sourceDigest":"source","sourceMessageId":7,"toolCatalogDigest":"tools",\
    "toolFacts":[],"usageRowIds":[11]}
    """

    // when
    let decoded = try JSONDecoder().decode(EvidencePayload.self, from: Data(json.utf8))
    let encoded = CanonicalJSON.encode(decoded)

    // then
    #expect(decoded.sourceMessageID == 7)
    #expect(decoded.usageRowIDs == [11])
    #expect(encoded == json)
  }
}

// MARK: - Legacy Rollback Payloads

private extension LearningPayloadCompatibilityTests {
  struct RollbackCase: Sendable {
    let json: String
    let trigger: RollbackTrigger
  }

  static let rollbackCases = [
    RollbackCase(
      json: #"{"ownerFeedback":{"eventId":8,"promotionId":7}}"#,
      trigger: .ownerFeedback(promotionID: 7, eventID: 8)
    ),
    RollbackCase(
      json: #"{"supportWithdrawal":{"eventId":10,"promotionId":9}}"#,
      trigger: .supportWithdrawal(promotionID: 9, eventID: 10)
    ),
    RollbackCase(
      json: #"{"adapter":{"adapterId":"adapter","outcome":"critical","promotionId":11}}"#,
      trigger: .adapter(promotionID: 11, adapterID: "adapter", outcome: .critical)
    ),
    RollbackCase(
      json: """
      {"safety":{"failure":"security","promotionId":12,"receiptDigest":"receipt"}}
      """,
      trigger: .safety(promotionID: 12, receiptDigest: "receipt", failure: .security)
    ),
  ]
}
