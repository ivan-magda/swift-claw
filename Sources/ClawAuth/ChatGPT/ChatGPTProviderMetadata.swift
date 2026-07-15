import ClawCore
import Foundation

/// The pinned ChatGPT protocol surface, and the one place authorization headers are built.
///
/// Every value below is an implementation constant observed in the studied clients, not
/// configuration: the vendor publishes no discovery document for this flow, so the daemon cannot
/// negotiate them. Changing one is a code change that must be backed by a fresh source study —
/// which is also why an owner cannot supply any of them. The Responses endpoint in particular is
/// fixed so that a bearer is only ever built after a URL we chose has been selected, leaving no
/// arrangement of configuration that can point a subscription token at another host.
public enum ChatGPTProviderMetadata {
  // MARK: - Identity

  /// The registered route's identity and prefix, read from the descriptor rather than restated. A
  /// second copy would let the stored credential key and the model an owner types drift apart.
  public static let providerID = LLMProviderDescriptor.openAIChatGPT.providerID

  /// Reconstructs the registry's own prefix rule if the descriptor ever stops carrying one, rather
  /// than defaulting to an empty prefix that would silently claim every unqualified model.
  public static let modelPrefix =
    LLMProviderDescriptor.openAIChatGPT.qualifiedPrefix
    ?? "\(LLMProviderID.openAIChatGPT.rawValue)/"

  // MARK: - OAuth

  public static let issuer = "https://auth.openai.com"
  public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

  public static let userCodeURL = "\(issuer)/api/accounts/deviceauth/usercode"
  public static let devicePollURL = "\(issuer)/api/accounts/deviceauth/token"
  public static let tokenURL = "\(issuer)/oauth/token"

  /// Where the owner is sent to approve the device, and the callback the exchange must echo. The
  /// callback is never listened on: this flow polls, and the value exists only because the token
  /// endpoint requires the code's original redirect.
  public static let verificationURL = "\(issuer)/codex/device"
  public static let redirectURI = "\(issuer)/deviceauth/callback"

  // MARK: - Backend

  public static let responsesURL = LLMProviderDescriptor.chatGPTResponsesEndpoint
  public static let modelsURL = "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0"
  public static let accountHeaderName = "ChatGPT-Account-ID"

  // MARK: - Timing

  /// How long an owner has to finish approving the device before login gives up.
  public static let maximumLoginWait = Duration.seconds(15 * 60)

  /// Used until the vendor names an interval, and the floor every named interval is clamped to —
  /// a server asking to be polled faster than this does not get to.
  public static let defaultPollInterval = Duration.seconds(5)
  public static let minimumPollInterval = Duration.seconds(1)

  /// How far ahead of a token's stated expiry it stops counting as fresh, absorbing clock drift and
  /// the flight time of the request that will carry it.
  public static let credentialFreshnessSkew = Duration.seconds(120)

  // MARK: - Authorization

  /// The sole builder of ChatGPT's credential-dependent headers, and the sole source of the exact
  /// values a diagnostic must scrub. Returning both together is what stops a caller from putting a
  /// token on the wire while forgetting to teach the redactor about it.
  ///
  /// Only credential-dependent headers appear here; content type, originator, and user agent belong
  /// to the wire adapter. The account claim is unverified metadata, so it is added only when it can
  /// safely be a header value and is otherwise omitted — a token whose account cannot be read is
  /// still a token the server may accept, and composition must not pre-empt that verdict.
  public static func authorization(
    accessToken: String,
    generation: LLMCredentialGeneration
  ) -> LLMRequestAuthorization {
    var headers = ["Authorization": "Bearer \(accessToken)"]
    var redactionValues = [accessToken]

    if let accountID = ChatGPTTokenMetadata.extract(accessToken: accessToken).accountID {
      headers[accountHeaderName] = accountID
      redactionValues.append(accountID)
    }

    return LLMRequestAuthorization(
      headers: headers,
      redactionValues: redactionValues,
      generation: generation
    )
  }
}
