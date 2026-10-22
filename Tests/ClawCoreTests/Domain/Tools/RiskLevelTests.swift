import Testing

@testable import ClawCore

@Suite
struct RiskLevelTests {
  @Test
  func rawValuesMatchTheFingerprintVocabulary() {
    // given / when / then — rawValues feed the §3.2 static sub-hash; renames void every
    // outstanding approval, so they are pinned here
    #expect(RiskLevel.safe.rawValue == "safe")
    #expect(RiskLevel.ask.rawValue == "ask")
    #expect(RiskLevel.dangerous.rawValue == "dangerous")
  }

  @Test
  func approvalReasonsHaveStableRawValues() {
    // given / when / then — the approvals.reason column vocabulary (spec §4.1)
    #expect(ApprovalReason.askTier.rawValue == "ask_tier")
    #expect(ApprovalReason.exfilTrifecta.rawValue == "exfil_trifecta")
    #expect(ApprovalReason.codeExec.rawValue == "code_exec")
  }
}
