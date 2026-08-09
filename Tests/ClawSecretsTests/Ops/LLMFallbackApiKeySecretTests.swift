import ClawCore
import Crypto
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct LLMFallbackApiKeySecretTests {
  @Test func envStoreReadsFallbackKeyAndTreatsEmptyAsAbsent() throws {
    // given
    let populated = EnvSecretStore(
      environment: [
        "CLAW_TELEGRAM_BOT_TOKEN": "123:abc",
        "CLAW_LLM_FALLBACK_API_KEY": "sk-fallback-1",
      ],
      warn: { _ in }
    )
    let empty = EnvSecretStore(
      environment: [
        "CLAW_TELEGRAM_BOT_TOKEN": "123:abc",
        "CLAW_LLM_FALLBACK_API_KEY": "",
      ],
      warn: { _ in }
    )

    // when / then
    #expect(try populated.loadSecrets().llmFallbackApiKey == "sk-fallback-1")
    #expect(try empty.loadSecrets().llmFallbackApiKey == nil)
  }

  @Test func encryptedPayloadRoundTripsFallbackKey() throws {
    // given
    let secrets = Secrets(
      telegramBotToken: "123:abc",
      llmApiKey: "sk-x",
      searchApiKey: "exa-key-1",
      llmFallbackApiKey: "sk-fallback-1"
    )

    // when
    let decoded = try EncryptedFileSecretStore.decode(EncryptedFileSecretStore.encode(secrets))

    // then
    #expect(decoded == secrets)
  }

  @Test func preFallbackEnvelopePayloadStillDecodes() throws {
    // given — the exact payload shape sealed before the fallback key existed: no
    // llm_fallback_api_key field at all. An owner's existing encrypted envelope must not break on
    // upgrade.
    let legacyPayload = Data(
      #"{"telegram_bot_token":"123:abc","llm_api_key":"sk-x","search_api_key":"exa-key-1"}"#
        .utf8
    )

    // when
    let decoded = try EncryptedFileSecretStore.decode(legacyPayload)

    // then
    #expect(decoded.telegramBotToken == "123:abc")
    #expect(decoded.llmApiKey == "sk-x")
    #expect(decoded.searchApiKey == "exa-key-1")
    #expect(decoded.llmFallbackApiKey == nil)
  }
}
