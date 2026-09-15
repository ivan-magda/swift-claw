import ClawCore
import Crypto
import Foundation
import Testing

@testable import ClawSecrets

@Suite
struct SearchAPIKeySecretTests {
  @Test
  func envStoreReadsSearchKeyAndTreatsEmptyAsAbsent() throws {
    // given
    let populated = EnvSecretStore(environment: [
      "CLAW_TELEGRAM_BOT_TOKEN": "123:abc",
      "CLAW_SEARCH_API_KEY": "exa-key-1",
    ]) { _ in }
    let empty = EnvSecretStore(environment: [
      "CLAW_TELEGRAM_BOT_TOKEN": "123:abc",
      "CLAW_SEARCH_API_KEY": "",
    ]) { _ in }

    // when / then
    #expect(try populated.loadSecrets().searchAPIKey == "exa-key-1")
    #expect(try empty.loadSecrets().searchAPIKey == nil)
  }

  @Test
  func encryptedPayloadRoundTripsSearchKey() throws {
    // given
    let secrets = Secrets(telegramBotToken: "123:abc", llmAPIKey: "sk-x", searchAPIKey: "exa-key-1")

    // when
    let decoded = try EncryptedFileSecretStore.decode(EncryptedFileSecretStore.encode(secrets))

    // then
    #expect(decoded == secrets)
  }

  @Test
  func preThreeBEnvelopePayloadStillDecodes() throws {
    // given — the exact payload shape sealed before 3b (no search_api_key)
    let legacyPayload = Data(#"{"telegram_bot_token":"123:abc","llm_api_key":"sk-x"}"#.utf8)

    // when
    let decoded = try EncryptedFileSecretStore.decode(legacyPayload)

    // then
    #expect(decoded.telegramBotToken == "123:abc")
    #expect(decoded.llmAPIKey == "sk-x")
    #expect(decoded.searchAPIKey == nil)
  }
}
