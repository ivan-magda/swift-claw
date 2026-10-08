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
      (flag: nil, owners: "42", groups: "", expected: .disabled),
      (flag: "true", owners: "42", groups: "", expected: .enabled),
      (flag: "false", owners: "", groups: "-100", expected: .disabled),
      (flag: "perhaps", owners: "42", groups: "", expected: .rejected),
      (flag: "true", owners: "", groups: "", expected: .rejected),
      (flag: "true", owners: "42,99", groups: "", expected: .rejected),
      (flag: "true", owners: "0", groups: "", expected: .rejected),
      (flag: "true", owners: "-42", groups: "", expected: .rejected),
      (flag: "true", owners: "42", groups: "-100", expected: .rejected),
    ] as [(flag: String?, owners: String, groups: String, expected: ExpectedEnablement)]
  )
  func journalRequiresOnePositivePersonalOwner(
    flag: String?,
    owners: String,
    groups: String,
    expected: ExpectedEnablement
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
      #expect(config.journalPolicy.ownerUserID == (owners == "42" ? 42 : nil))
    case .rejected:
      let error: ConfigError =
        flag == "perhaps"
        ? .invalidBool(key: AppConfig.EnvKey.journalEnabled, value: "perhaps")
        : .journalRequiresPersonalOwner
      #expect(throws: error) {
        _ = try AppConfig.load(environment: environment)
      }
    }
  }
}
