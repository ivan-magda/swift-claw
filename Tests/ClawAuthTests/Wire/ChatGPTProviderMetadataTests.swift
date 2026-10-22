import ClawCore
import Foundation
import Testing

@testable import ClawAuth

@Suite
struct ChatGPTProviderMetadataTests {
  // MARK: - Pinned Protocol Values

  /// The values observed in the studied clients. They are provider implementation constants, not
  /// configuration: this test is the diff a reviewer reads, so each literal is spelled out here
  /// rather than derived from the source under test.
  @Test
  func protocolValuesMatchTheStudiedClients() {
    // given / when / then
    #expect(ChatGPTProviderMetadata.issuer == "https://auth.openai.com")
    #expect(ChatGPTProviderMetadata.clientID == "app_EMoamEEZ73f0CkXaXp7hrann")
    #expect(
      ChatGPTProviderMetadata.userCodeURL
        == "https://auth.openai.com/api/accounts/deviceauth/usercode"
    )
    #expect(
      ChatGPTProviderMetadata.devicePollURL
        == "https://auth.openai.com/api/accounts/deviceauth/token"
    )
    #expect(ChatGPTProviderMetadata.tokenURL == "https://auth.openai.com/oauth/token")
    #expect(ChatGPTProviderMetadata.verificationURL == "https://auth.openai.com/codex/device")
    #expect(ChatGPTProviderMetadata.redirectURI == "https://auth.openai.com/deviceauth/callback")
    #expect(
      ChatGPTProviderMetadata.responsesURL == "https://chatgpt.com/backend-api/codex/responses"
    )
    #expect(
      ChatGPTProviderMetadata.modelsURL
        == "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0"
    )
    #expect(ChatGPTProviderMetadata.accountHeaderName == "ChatGPT-Account-ID")
  }

  @Test
  func pinnedDurationsMatchTheStudiedClients() {
    // given / when / then
    #expect(ChatGPTProviderMetadata.maximumLoginWait == .seconds(15 * 60))
    #expect(ChatGPTProviderMetadata.defaultPollInterval == .seconds(5))
    #expect(ChatGPTProviderMetadata.minimumPollInterval == .seconds(1))
    #expect(ChatGPTProviderMetadata.credentialFreshnessSkew == .seconds(120))
  }

  // MARK: - Authorization: Bearer

  @Test
  func authorizationCarriesTheBearerAndTheCallersGeneration() {
    // given
    let token = TokenBuilder.accessToken(accountID: nil)

    // when
    let authorization = ChatGPTProviderMetadata.authorization(
      accessToken: token,
      generation: LLMCredentialGeneration(value: 7)
    )

    // then
    #expect(authorization.headers["Authorization"] == "Bearer \(token)")
    #expect(authorization.generation == LLMCredentialGeneration(value: 7))
  }

  // MARK: - Authorization: Account Header

  @Test
  func authorizationAddsAndRedactsAUsableAccountClaim() {
    // given
    let token = TokenBuilder.accessToken(accountID: "acct-abc-123")

    // when
    let authorization = ChatGPTProviderMetadata.authorization(accessToken: token, generation: .zero)

    // then
    #expect(authorization.headers["ChatGPT-Account-ID"] == "acct-abc-123")
    #expect(authorization.redactionValues.contains("acct-abc-123"))
    #expect(authorization.redactionValues.contains(token))
  }

  /// One row per outcome of the only branch composition owns: whether `extract` yields an account.
  /// Which claims are unusable is `ChatGPTTokenMetadataTests`' contract, so it is not re-run here.
  @Test(arguments: [
    // No account claim at all.
    TokenBuilder.accessToken(accountID: nil),
    // A value that would smuggle a second header past a naive builder.
    TokenBuilder.accessToken(accountID: #"acct\r\nX-Injected: yes"#),
  ])
  func authorizationOmitsTheAccountHeaderForAnUnusableClaim(token: String) {
    // given / when
    let authorization = ChatGPTProviderMetadata.authorization(accessToken: token, generation: .zero)

    // then
    #expect(authorization.headers["ChatGPT-Account-ID"] == nil)
    #expect(authorization.headers["Authorization"] == "Bearer \(token)")
  }

  // MARK: - Authorization: Header Surface

  @Test
  func authorizationReturnsOnlyCredentialDependentHeaders() {
    // given
    // Content type, originator, and user agent belong to the wire adapter; a credential source
    // that also owned them would leak provider transport concerns into the auth seam.
    let token = TokenBuilder.accessToken(accountID: "acct-1")

    // when
    let authorization = ChatGPTProviderMetadata.authorization(accessToken: token, generation: .zero)

    // then
    #expect(Set(authorization.headers.keys) == ["Authorization", "ChatGPT-Account-ID"])
  }
}
