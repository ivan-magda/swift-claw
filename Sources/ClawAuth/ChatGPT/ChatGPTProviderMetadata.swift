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

  /// The registered route's prefix, read from the descriptor rather than restated. A qualified route
  /// must carry one; a nil would mean the registry stopped qualifying this route, and printing an
  /// unprefixed assignment would send the owner's model to the unqualified fallback instead — so an
  /// absent prefix fails loudly here rather than misrouting in silence.
  public static let modelPrefix: String = {
    guard let prefix = LLMProviderDescriptor.openAIChatGPT.qualifiedPrefix else {
      preconditionFailure("The ChatGPT route lost its qualified prefix.")
    }
    return prefix
  }()

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

  /// The ceiling on any single auth request. A login is a conversation of several short calls, and
  /// no one of them has business spending a noticeable slice of the owner's window; what actually
  /// protects that window is the caller's remaining deadline, which cuts this down further.
  public static let requestTimeout = Duration.seconds(30)

  /// The delay this provider will actually wait, whatever was asked for. The floor is what stops a
  /// poll loop from becoming a spin — including on a value no current parser can produce, since the
  /// alternative is a guard that only exists in the sentence that describes it.
  public static func honoredPollDelay(_ requested: Duration) -> Duration {
    max(requested, minimumPollInterval)
  }

  /// A relative timeout as the whole seconds the transport counts in. Rounded up and floored at one
  /// second: a zero would read as "no timeout at all" to a transport, which is the exact opposite of
  /// what a closing window is asking for. The sub-second overshoot cannot compound, because a caller
  /// with a deadline recomputes what is left before every call.
  public static func transportSeconds(_ timeout: Duration) -> Int {
    let parts = timeout.components
    let whole = Int(clamping: parts.seconds)
    guard parts.attoseconds > 0, whole < Int.max else {
      return max(1, whole)
    }
    return max(1, whole + 1)
  }

  // MARK: - Bounds

  /// What a response may cost to read. The two caps part company because they answer different
  /// questions: a success body is the payload the flow cannot proceed without, while a non-success
  /// body is a diagnostic whose first few kilobytes are the only useful ones. Capping at read time,
  /// rather than after, is what keeps an unbounded body from being materialized before the sanitizer
  /// that would have trimmed it ever runs.
  public static let maximumAuthResponseBytes = 256 * 1024
  public static let maximumDiagnosticBytes = 8 * 1024

  /// The catalog's own success cap. It is roomier than an auth response because it carries a row per
  /// offered model rather than a handful of fields, and it is still a cap: nothing downstream keeps
  /// more than a bounded, deduplicated slice of what arrives.
  public static let maximumCatalogResponseBytes = 1024 * 1024

  /// What the vendor's own values may weigh. Each is measured in UTF-8 bytes, generously above any
  /// value the flow is observed to carry, and present so that a hostile or broken response cannot
  /// spend the daemon's memory or widen what it prints.
  public static let maximumUserCodeBytes = 128
  public static let maximumDeviceAuthIDBytes = 4 * 1024
  /// The authorization code and the code verifier alike.
  public static let maximumGrantValueBytes = 16 * 1024
  public static let maximumTokenBytes = 64 * 1024

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

  // MARK: - Diagnostics

  /// Sanitizes and redacts vendor-supplied text for display, bounded by the diagnostic cap. The one
  /// wrapper the two wire clients and the result mapper share, so the byte bound they scrub to and the
  /// sanitizer they route through cannot drift between them.
  static func safeDiagnostic(_ raw: String, redacting secrets: [String]) -> String {
    ChatGPTWireValues.safeRemoteDiagnostic(
      raw,
      redacting: secrets,
      maxBytes: maximumDiagnosticBytes
    )
  }

  // MARK: - Transport

  /// Runs one request and turns a transport failure into the caller's own failure type through the
  /// shared diagnostic — one home, so the load-bearing catch order below cannot drift between the two
  /// wire clients that depend on it.
  ///
  /// Cancellation is rethrown untouched ahead of every catch-all: it is the caller walking away, not
  /// the vendor failing, and reclassifying it would make an abandoned call look retryable.
  static func execute<Failure: Error>(
    _ request: HTTPRequest,
    on http: any HTTPExecuting,
    redacting secrets: [String],
    onTransportFailure asFailure: (String) -> Failure
  ) async throws -> HTTPResult {
    do {
      return try await http.execute(request)
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch let failure as HTTPTransportFailure {
      throw asFailure(safeDiagnostic(failure.safeMessage, redacting: secrets))
    } catch {
      throw asFailure(safeDiagnostic("\(error)", redacting: secrets))
    }
  }
}
