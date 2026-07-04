import Foundation
import Testing

@testable import ClawCore

@Suite struct RunBudgetToolPinsTests {
  private func baseEnvironment() -> [String: String] {
    [
      "CLAW_LLM_BASE_URL": "http://localhost:1234/v1",
      "CLAW_LLM_MODEL": "test-model",
      "CLAW_STATE_ROOT": FileManager.default.temporaryDirectory
        .appendingPathComponent("claw-test-\(UUID().uuidString)").path,
    ]
  }

  @Test func defaultsArePinnedToSpecValues() {
    // given / when / then — §5.3 pins
    #expect(RunBudget.default.maxTurns == 12)
    #expect(RunBudget.default.maxToolCalls == 20)
  }

  @Test func envOverridesParsePositiveIntegers() throws {
    // given
    var environment = baseEnvironment()
    environment["CLAW_MAX_TURNS"] = "3"
    environment["CLAW_MAX_TOOL_CALLS"] = "7"

    // when
    let config = try AppConfig.load(environment: environment)

    // then
    #expect(config.budget.maxTurns == 3)
    #expect(config.budget.maxToolCalls == 7)
  }

  @Test func invalidOverrideFailsClosed() {
    // given
    var environment = baseEnvironment()
    environment["CLAW_MAX_TURNS"] = "zero"

    // when / then
    #expect(throws: ConfigError.self) {
      _ = try AppConfig.load(environment: environment)
    }
  }
}
