import Foundation
import Testing

@testable import ClawCore

@Suite
struct JournalConfigTests {
  enum ExpectedEnablement: Sendable {
    case disabled
    case enabled
    case rejected
  }

  @Test(
    arguments: [
      (flag: nil, owners: "42", groups: "", expected: .disabled, owner: 42),
      (flag: "true", owners: "42", groups: "", expected: .enabled, owner: 42),
      (flag: "false", owners: "", groups: "-100", expected: .disabled, owner: nil),
      (flag: "true", owners: "", groups: "", expected: .rejected, owner: nil),
      (flag: "true", owners: "42,99", groups: "", expected: .rejected, owner: nil),
      (flag: "true", owners: "0", groups: "", expected: .rejected, owner: nil),
      (flag: "true", owners: "-42", groups: "", expected: .rejected, owner: nil),
      (flag: "true", owners: "42", groups: "-100", expected: .rejected, owner: nil),
    ]
      as [(
        flag: String?,
        owners: String,
        groups: String,
        expected: ExpectedEnablement,
        owner: Int64?
      )]
  )
  func journalRequiresOnePositivePersonalOwner(
    flag: String?,
    owners: String,
    groups: String,
    expected: ExpectedEnablement,
    owner: Int64?
  ) throws {
    // given
    var environment = [
      "CLAW_STATE_ROOT": NSTemporaryDirectory(),
      "CLAW_LLM_BASE_URL": "http://localhost:1234/v1",
      "CLAW_LLM_MODEL": "gpt-4o",
      "CLAW_ALLOWLIST": owners,
      "CLAW_GROUP_CHATS": groups,
      "CLAW_TIMEZONE": "Europe/Istanbul",
    ]
    environment["CLAW_JOURNAL_ENABLED"] = flag

    // when / then
    switch expected {
    case .disabled, .enabled:
      let config = try AppConfig.load(environment: environment)
      #expect(config.journalEnabled == (expected == .enabled))
      #expect(config.journalPolicy.timeZoneID == "Europe/Istanbul")
      #expect(config.journalPolicy.ownerUserID == owner)
    case .rejected:
      #expect(throws: ConfigError.journalRequiresPersonalOwner) {
        _ = try AppConfig.load(environment: environment)
      }
    }
  }
}
