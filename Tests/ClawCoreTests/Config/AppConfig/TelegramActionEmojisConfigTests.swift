import Foundation
import Testing

@testable import ClawCore

@Suite
struct TelegramActionEmojisConfigTests {
  @Test
  func actionEmojisDefaultOffAndParseAnOptIn() throws {
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
    let enabledConfig = try AppConfig.load(
      environment: environment.merging([AppConfig.EnvKey.telegramActionEmojis: "true"]) { _, new in
        new
      }
    )

    // then
    #expect(defaultConfig.telegramActionEmojisEnabled == false)
    #expect(enabledConfig.telegramActionEmojisEnabled)
  }
}
