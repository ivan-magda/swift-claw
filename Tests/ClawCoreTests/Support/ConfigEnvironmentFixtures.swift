import Foundation

@testable import ClawCore

/// A ChatGPT model with no base URL and no key at all, to prove the managed route neither reads nor
/// requires either.
func chatGPTEnv(_ overrides: [String: String] = [:]) -> [String: String] {
  [
    AppConfig.EnvKey.stateRoot: NSTemporaryDirectory(),
    AppConfig.EnvKey.llmModel: "openai-chatgpt/gpt-5.4",
  ].merging(overrides) { _, new in
    new
  }
}
