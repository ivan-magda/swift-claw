import Foundation
import Testing

@testable import ClawCore

@Suite
struct TelegramProgressConfigTests {
  @Test
  func telegramProgressDefaultsOnAndRejectsInvalidValues() throws {
    // given
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmBaseURL: "http://localhost:9/v1",
      AppConfig.EnvKey.llmModel: "test-model",
    ]

    // when
    let defaultConfig = try AppConfig.load(environment: environment)
    let disabledConfig = try AppConfig.load(
      environment: environment.merging([AppConfig.EnvKey.telegramProgress: "false"]) { _, new in
        new
      }
    )

    // then
    #expect(defaultConfig.telegramProgressEnabled)
    #expect(disabledConfig.telegramProgressEnabled == false)
    #expect(throws: ConfigError.invalidBool(key: AppConfig.EnvKey.telegramProgress, value: "maybe"))
    {
      _ = try AppConfig.load(
        environment: environment.merging([AppConfig.EnvKey.telegramProgress: "maybe"]) { _, new in
          new
        }
      )
    }
  }
}
