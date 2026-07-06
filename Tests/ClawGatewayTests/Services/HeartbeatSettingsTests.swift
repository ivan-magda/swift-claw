import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct HeartbeatSettingsTests {
  private func loadConfig(allowlist: String, enabled: Bool) throws -> AppConfig {
    var env: [String: String] = [
      "CLAW_LLM_BASE_URL": "http://localhost:9/v1",
      "CLAW_LLM_MODEL": "test-model",
      "CLAW_STATE_ROOT": NSTemporaryDirectory(),
      "CLAW_ALLOWLIST": allowlist,
      "CLAW_TIMEZONE": "Europe/Berlin",
      "CLAW_HEARTBEAT_INTERVAL_MINUTES": "30",
      "CLAW_HEARTBEAT_QUIET_HOURS": "23:00-08:00",
      "CLAW_HEARTBEAT_MAX_PER_DAY": "4",
    ]
    env["CLAW_HEARTBEAT_ENABLED"] = enabled ? "true" : "false"
    return try AppConfig.load(environment: env)
  }

  @Test func resolveMapsEveryConfigFieldAndTheSingleOwner() throws {
    // given
    let config = try loadConfig(allowlist: "777", enabled: true)

    // when
    let settings = HeartbeatSettings.resolve(config: config)

    // then
    #expect(settings.enabled)
    #expect(settings.intervalMinutes == 30)
    #expect(settings.quietHours.rendered == "23:00-08:00")
    #expect(settings.maxPerDay == 4)
    #expect(settings.ownerChatId == 777)
    #expect(settings.timezone.identifier == "Europe/Berlin")
  }

  @Test func resolveWithoutASingleOwnerYieldsNilTarget() throws {
    // given — reachable only with the heartbeat DISABLED (Cycle B rejects enabled+ambiguous)
    let config = try loadConfig(allowlist: "1,2", enabled: false)

    // when
    let settings = HeartbeatSettings.resolve(config: config)

    // then
    #expect(settings.enabled == false)
    #expect(settings.ownerChatId == nil)
  }

  @Test func disabledBundleIsOffWithNoTarget() {
    // given / when / then
    #expect(HeartbeatSettings.disabled.enabled == false)
    #expect(HeartbeatSettings.disabled.ownerChatId == nil)
    #expect(HeartbeatSettings.disabled.maxPerDay == 8)
  }

  @Test func templateWrapsTheChecklistUnderTheVerbatimContractSentence() {
    // given
    let checklist = "- check backups\n- check inbox"

    // when
    let prompt = HeartbeatTemplate.prompt(checklist: checklist)

    // then — the contract sentence is pinned verbatim (spec §12)
    #expect(
      HeartbeatTemplate.contractSentence
        == "Review the checklist below. If something needs the owner's attention, say it "
        + "concisely. If nothing does, reply exactly HEARTBEAT_OK."
    )
    #expect(prompt == HeartbeatTemplate.contractSentence + "\n\n" + checklist)
  }
}
