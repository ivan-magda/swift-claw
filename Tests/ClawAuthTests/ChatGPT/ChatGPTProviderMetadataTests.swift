import ClawCore
import Foundation
import Testing

@testable import ClawAuth

/// Builds a JWT-shaped access token carrying the given account claim. The parser never verifies a
/// signature, so the third segment is arbitrary text.
private func accessToken(accountID: String?) -> String {
  let payload: String
  if let accountID {
    payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)"}}"#
  } else {
    payload = #"{"sub":"user"}"#
  }
  func encode(_ json: String) -> String {
    Data(json.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  return "\(encode(#"{"alg":"none"}"#)).\(encode(payload)).signature-not-verified"
}

@Suite struct ChatGPTProviderMetadataTests {
  // MARK: - Pinned Protocol Values

  /// The values observed in the studied clients. They are provider implementation constants, not
  /// configuration: this test is the diff a reviewer reads, so each literal is spelled out here
  /// rather than derived from the source under test.
  @Test func protocolValuesMatchTheStudiedClients() {
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
    #expect(
      ChatGPTProviderMetadata.redirectURI == "https://auth.openai.com/deviceauth/callback"
    )
    #expect(
      ChatGPTProviderMetadata.responsesURL == "https://chatgpt.com/backend-api/codex/responses"
    )
    #expect(
      ChatGPTProviderMetadata.modelsURL
        == "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0"
    )
    #expect(ChatGPTProviderMetadata.accountHeaderName == "ChatGPT-Account-ID")
  }

  @Test func pinnedDurationsMatchTheStudiedClients() {
    // given / when / then
    #expect(ChatGPTProviderMetadata.maximumLoginWait == .seconds(15 * 60))
    #expect(ChatGPTProviderMetadata.defaultPollInterval == .seconds(5))
    #expect(ChatGPTProviderMetadata.minimumPollInterval == .seconds(1))
    #expect(ChatGPTProviderMetadata.credentialFreshnessSkew == .seconds(120))
  }

  @Test func everyDeviceAuthUrlIsBuiltOnThePinnedIssuer() {
    // given
    let issued = [
      ChatGPTProviderMetadata.userCodeURL,
      ChatGPTProviderMetadata.devicePollURL,
      ChatGPTProviderMetadata.tokenURL,
      ChatGPTProviderMetadata.verificationURL,
      ChatGPTProviderMetadata.redirectURI,
    ]

    // when / then
    for url in issued {
      #expect(url.hasPrefix(ChatGPTProviderMetadata.issuer + "/"))
    }
  }

  // MARK: - Reused Identity

  @Test func identityIsTheRegisteredRouteRatherThanASecondDeclaration() {
    // given / when / then
    #expect(ChatGPTProviderMetadata.providerID == .openAIChatGPT)
    #expect(ChatGPTProviderMetadata.providerID == LLMProviderDescriptor.openAIChatGPT.providerID)
    #expect(ChatGPTProviderMetadata.modelPrefix == "openai-chatgpt/")
    #expect(
      ChatGPTProviderMetadata.modelPrefix == LLMProviderDescriptor.openAIChatGPT.qualifiedPrefix
    )
    #expect(ChatGPTProviderMetadata.responsesURL == LLMProviderDescriptor.chatGPTResponsesEndpoint)
  }

  // MARK: - Authorization: Bearer

  @Test func authorizationCarriesTheBearerAndTheCallersGeneration() {
    // given
    let token = accessToken(accountID: nil)

    // when
    let authorization = ChatGPTProviderMetadata.authorization(
      accessToken: token,
      generation: LLMCredentialGeneration(value: 7)
    )

    // then
    #expect(authorization.headers["Authorization"] == "Bearer \(token)")
    #expect(authorization.generation == LLMCredentialGeneration(value: 7))
  }

  @Test func authorizationRedactsTheAccessTokenItPutsOnTheWire() {
    // given
    let token = accessToken(accountID: nil)

    // when
    let authorization = ChatGPTProviderMetadata.authorization(
      accessToken: token,
      generation: .zero
    )

    // then
    #expect(authorization.redactionValues.contains(token))
  }

  // MARK: - Authorization: Account Header

  @Test func authorizationAddsAndRedactsAUsableAccountClaim() {
    // given
    let token = accessToken(accountID: "acct-abc-123")

    // when
    let authorization = ChatGPTProviderMetadata.authorization(
      accessToken: token,
      generation: .zero
    )

    // then
    #expect(authorization.headers["ChatGPT-Account-ID"] == "acct-abc-123")
    #expect(authorization.redactionValues.contains("acct-abc-123"))
    #expect(authorization.redactionValues.contains(token))
  }

  @Test(arguments: [
    // No account claim at all.
    accessToken(accountID: nil),
    // An empty account value.
    accessToken(accountID: ""),
    // A value that would smuggle a second header past a naive builder.
    accessToken(accountID: #"acct\r\nX-Injected: yes"#),
    // Whitespace and controls a header value must never carry.
    accessToken(accountID: "acct with space"),
    accessToken(accountID: #"acct\u0000nul"#),
    accessToken(accountID: #"acct\u001b[31m"#),
    // Non-ASCII bytes.
    accessToken(accountID: "acct-é"),
    // Over the 256-byte bar.
    accessToken(accountID: String(repeating: "a", count: 257)),
    // Not a JWT at all.
    "not-a-jwt",
    "",
  ])
  func authorizationOmitsTheAccountHeaderForAnUnusableClaim(token: String) {
    // given / when
    let authorization = ChatGPTProviderMetadata.authorization(
      accessToken: token,
      generation: .zero
    )

    // then
    #expect(authorization.headers["ChatGPT-Account-ID"] == nil)
    #expect(authorization.headers["Authorization"] == "Bearer \(token)")
  }

  @Test func authorizationComposesFromAMalformedTokenRatherThanFailing() {
    // given
    // A token the parser cannot read is still handed to the server, which is the only party that
    // can judge it. Composition must not treat an unreadable claim as a credential failure.
    let token = "garbage.not-base64url.at-all"

    // when
    let authorization = ChatGPTProviderMetadata.authorization(
      accessToken: token,
      generation: .zero
    )

    // then
    #expect(authorization.headers["Authorization"] == "Bearer \(token)")
    #expect(authorization.headers.count == 1)
  }

  // MARK: - Authorization: Header Surface

  @Test func authorizationReturnsOnlyCredentialDependentHeaders() {
    // given
    // Content type, originator, and user agent belong to the wire adapter; a credential source
    // that also owned them would leak provider transport concerns into the auth seam.
    let token = accessToken(accountID: "acct-1")

    // when
    let authorization = ChatGPTProviderMetadata.authorization(
      accessToken: token,
      generation: .zero
    )

    // then
    #expect(Set(authorization.headers.keys) == ["Authorization", "ChatGPT-Account-ID"])
  }
}
