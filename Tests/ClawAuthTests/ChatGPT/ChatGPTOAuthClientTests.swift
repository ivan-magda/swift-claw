import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

/// Fails every call with a freshly built error. A factory rather than a stored value, because an
/// `any Error` is not `Sendable` and the seam it is handed to is.
private struct FailingHTTP: HTTPExecuting {
  let makeFailure: @Sendable () -> any Error

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    throw makeFailure()
  }
}

/// The shared scripted values for both ChatGPT OAuth suites: the wire client's and the device
/// coordinator's. Module-scoped rather than file-private, so the two suites cannot drift into
/// disagreeing about what a well-formed device code or grant looks like.
enum OAuthFixture {
  static let deviceAuthID = "device-auth-id-1"
  static let userCode = "ABCD-1234"
  static let accessToken = "access-token-value"
  static let refreshToken = "refresh-token-value"
  static let authorizationCode = "auth-code-value"
  static let codeVerifier = "code-verifier-value"

  /// The one wall date every expiry expectation is measured from. Fixed, so a test can name the
  /// exact instant a token expires at instead of a tolerance around the process clock.
  static let wallNow = Date(timeIntervalSince1970: 1_800_000_000)

  static let grant = ChatGPTAuthorizationGrant(
    authorizationCode: authorizationCode,
    codeVerifier: codeVerifier
  )

  static let device = ChatGPTDeviceCode(
    deviceAuthID: deviceAuthID,
    userCode: userCode,
    pollInterval: .seconds(5)
  )

  static func client(_ http: any HTTPExecuting) -> ChatGPTOAuthClient {
    ChatGPTOAuthClient(http: http) { wallNow }
  }

  static func result(
    _ statusCode: Int,
    _ body: String,
    headers: [String: String] = [:]
  ) -> HTTPResult {
    HTTPResult(statusCode: statusCode, headers: headers, body: Data(body.utf8))
  }

  static func executor(_ url: String, _ result: HTTPResult) -> RecordingHTTPExecutor {
    RecordingHTTPExecutor(responses: [url: result])
  }

  /// Wraps scripted fields into a JSON object, so a case can state only the fields it varies.
  static func json(_ fields: String) -> String {
    "{\(fields)}"
  }

  /// A JWT-shaped access token whose only claim is the expiry the fallback path reads.
  static func token(expiringAt seconds: Int) -> String {
    TokenBuilder.token(payload: #"{"exp":\#(seconds)}"#)
  }
}

/// Case matchers for the failures whose detail text is composed at runtime and so cannot be
/// written into an equality expectation.
extension ChatGPTOAuthFailure {
  var isMalformed: Bool {
    guard case .malformedResponse = self else { return false }
    return true
  }

  var isGrantRejected: Bool {
    guard case .grantRejected = self else { return false }
    return true
  }

  var isTransport: Bool {
    guard case .transport = self else { return false }
    return true
  }

  var detail: String? {
    switch self {
    case .malformedResponse(let detail), .grantRejected(let detail), .transport(let detail):
      return detail
    case .throttled, .deadlineExceeded:
      return nil
    }
  }
}

private extension RecordedHTTPRequest {
  /// The bytes this request actually carried, read back as the text they were built from.
  var bodyText: String? {
    body.flatMap { bytes in
      String(bytes: bytes, encoding: .utf8)
    }
  }
}

@Suite struct ChatGPTOAuthClientTests {
  // MARK: - Device Code: Request Shape

  @Test func deviceCodeRequestCarriesExactlyTheClientID() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(200, #"{"device_auth_id":"device-auth-id-1","user_code":"ABCD-1234"}"#)
    )

    // when
    _ = try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))

    // then
    let sent = try #require(await http.requests.first)
    #expect(sent.method == .post)
    #expect(sent.url == ChatGPTProviderMetadata.userCodeURL)
    #expect(sent.headers["Content-Type"] == "application/json")
    #expect(
      sent.bodyText
        == #"{"client_id":"\#(ChatGPTProviderMetadata.clientID)"}"#
    )
  }

  @Test func anAuthRequestCapsItsSuccessAndDiagnosticBodiesAtReadTime() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(200, #"{"device_auth_id":"device-auth-id-1","user_code":"ABCD-1234"}"#)
    )

    // when
    _ = try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))

    // then
    let sent = try #require(await http.requests.first)
    #expect(
      sent.responseBodyPolicy
        == .buffered(
          successBytes: ChatGPTProviderMetadata.maximumAuthResponseBytes,
          errorBytes: ChatGPTProviderMetadata.maximumDiagnosticBytes
        )
    )
    #expect(sent.selectedBodyCap == ChatGPTProviderMetadata.maximumAuthResponseBytes)
  }

  @Test(arguments: [
    (Duration.seconds(30), 30),
    (Duration.seconds(7), 7),
    // A sub-second remainder still buys a whole second: a zero-second timeout reads as "no timeout"
    // to a transport, which is the opposite of what a closing window is asking for.
    (Duration.milliseconds(1500), 2),
    (Duration.milliseconds(1), 1),
  ])
  func aRequestTimeoutIsCarriedAsWholeSecondsAndNeverRoundsDownToZero(
    timeout: Duration,
    expected: Int
  ) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(200, #"{"device_auth_id":"device-auth-id-1","user_code":"ABCD-1234"}"#)
    )

    // when
    _ = try await OAuthFixture.client(http).requestDeviceCode(timeout: timeout)

    // then
    let sent = try #require(await http.requests.first)
    #expect(sent.timeoutSeconds == expected)
  }

  // MARK: - Device Code: Response Reading

  @Test func deviceCodeReadsTheIdentifiersAndTheServerInterval() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(
        200,
        #"{"device_auth_id":"device-auth-id-1","user_code":"ABCD-1234","interval":7}"#
      )
    )

    // when
    let device = try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.deviceAuthID == OAuthFixture.deviceAuthID)
    #expect(device.userCode == OAuthFixture.userCode)
    #expect(device.pollInterval == .seconds(7))
  }

  @Test func deviceCodeAcceptsTheObservedUserCodeAlias() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(200, #"{"device_auth_id":"device-auth-id-1","usercode":"ABCD-1234"}"#)
    )

    // when
    let device = try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.userCode == OAuthFixture.userCode)
  }

  @Test(arguments: [
    #""interval":7"#,
    // A decimal string is the vendor's other observed encoding for the same field.
    #""interval":"7""#,
  ])
  func deviceCodeAcceptsAnIntervalAsANumberOrADecimalString(field: String) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(#""device_auth_id":"device-auth-id-1","user_code":"ABCD-1234",\#(field)"#)
      )
    )

    // when
    let device = try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.pollInterval == .seconds(7))
  }

  @Test(arguments: [
    // Absent entirely.
    "",
    // Encodings that would spin or stall the poll loop if they were coerced instead of refused.
    #","interval":0"#,
    #","interval":-5"#,
    #","interval":0.5"#,
    #","interval":"soon""#,
    #","interval":null"#,
  ])
  func deviceCodeFallsBackToThePinnedIntervalWhenTheServerNamesNoUsableOne(
    field: String
  ) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(#""device_auth_id":"device-auth-id-1","user_code":"ABCD-1234"\#(field)"#)
      )
    )

    // when
    let device = try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.pollInterval == ChatGPTProviderMetadata.defaultPollInterval)
  }

  // MARK: - Device Code: Rejected Identifiers

  @Test(arguments: [
    // Missing either half.
    #""user_code":"ABCD-1234""#,
    #""device_auth_id":"device-auth-id-1""#,
    // Wrong JSON type.
    #""device_auth_id":17,"user_code":"ABCD-1234""#,
    #""device_auth_id":"device-auth-id-1","user_code":true"#,
    // Empty.
    #""device_auth_id":"","user_code":"ABCD-1234""#,
    #""device_auth_id":"device-auth-id-1","user_code":"""#,
    // A user code that would repaint the terminal it is printed on.
    #""device_auth_id":"device-auth-id-1","user_code":"AB\u001b[31mCD""#,
    // A device-auth ID carrying a control byte.
    #""device_auth_id":"dev\u0000null","user_code":"ABCD-1234""#,
  ])
  func deviceCodeRefusesAnUnusableIdentifier(fields: String) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(200, OAuthFixture.json(fields))
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  @Test(arguments: [
    // One byte past the user-code bound, alongside a device-auth ID that is fine.
    (ChatGPTProviderMetadata.maximumUserCodeBytes + 1, 16),
    // One byte past the device-auth-ID bound, alongside a user code that is fine.
    (8, ChatGPTProviderMetadata.maximumDeviceAuthIDBytes + 1),
  ])
  func deviceCodeRefusesAnIdentifierPastItsByteBound(
    userCodeBytes: Int,
    deviceAuthIDBytes: Int
  ) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(
          #""device_auth_id":"\#(String(repeating: "d", count: deviceAuthIDBytes))","#
            + #""user_code":"\#(String(repeating: "u", count: userCodeBytes))""#
        )
      )
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  /// The other side of the bound. Without it, the rejections above could be the decoder choking on
  /// the size of the body rather than the guard under test refusing the value.
  @Test func deviceCodeAcceptsIdentifiersSittingExactlyOnTheirByteBound() async throws {
    // given
    let codeAtBound = String(repeating: "u", count: ChatGPTProviderMetadata.maximumUserCodeBytes)
    let idAtBound = String(repeating: "d", count: ChatGPTProviderMetadata.maximumDeviceAuthIDBytes)
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(#""device_auth_id":"\#(idAtBound)","user_code":"\#(codeAtBound)""#)
      )
    )

    // when
    let device = try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.userCode == codeAtBound)
    #expect(device.deviceAuthID == idAtBound)
  }

  // MARK: - Device Code: Redaction

  @Test func aDeviceCodeNeverPrintsItsDeviceAuthID() {
    // given
    let device = OAuthFixture.device

    // when
    let printed = "\(device) \(String(describing: device)) \(String(reflecting: device))"

    // then
    #expect(printed.contains(OAuthFixture.deviceAuthID) == false)
    #expect(printed.contains(OAuthFixture.userCode))
  }

  // MARK: - Poll: Request Shape

  @Test func pollCarriesTheDeviceAuthIDAndUserCode() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(404, "{}")
    )

    // when
    _ = try await OAuthFixture.client(http).pollOnce(
      device: OAuthFixture.device,
      timeout: .seconds(30)
    )

    // then
    let sent = try #require(await http.requests.first)
    #expect(sent.method == .post)
    #expect(sent.url == ChatGPTProviderMetadata.devicePollURL)
    #expect(sent.headers["Content-Type"] == "application/json")
    #expect(
      sent.bodyText
        == #"{"device_auth_id":"device-auth-id-1","user_code":"ABCD-1234"}"#
    )
  }

  // MARK: - Poll: Status Rules

  @Test(arguments: [403, 404])
  func pollTreatsForbiddenAndNotFoundAsStillPending(statusCode: Int) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(statusCode, #"{"error":"authorization_pending"}"#)
    )

    // when
    let result = try await OAuthFixture.client(http)
      .pollOnce(device: OAuthFixture.device, timeout: .seconds(30))

    // then
    #expect(result == .pending)
  }

  @Test(arguments: [400, 401, 410, 418, 500, 503])
  func pollFailsImmediatelyOnEveryOtherNonSuccessStatus(statusCode: Int) async {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(statusCode, #"{"error":"nope"}"#)
    )

    // when / then
    await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).pollOnce(
        device: OAuthFixture.device,
        timeout: .seconds(30)
      )
    }
  }

  /// The pending rule belongs to the device poll alone. The same status at the token endpoint is a
  /// dead grant, and treating it as "keep waiting" would hang a refresh forever.
  @Test(arguments: [400, 401, 403])
  func aRejectedGrantIsTerminalRatherThanPendingOrRetryable(statusCode: Int) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(statusCode, #"{"error":"invalid_grant"}"#)
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http)
        .refresh(refreshToken: OAuthFixture.refreshToken, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isGrantRejected == true)
  }

  @Test(arguments: [408, 500, 502, 503])
  func aServerSideFailureIsReportedAsTransportRatherThanADeadGrant(statusCode: Int) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(statusCode, #"{"error":"server_error"}"#)
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http)
        .refresh(refreshToken: OAuthFixture.refreshToken, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isTransport == true)
  }

  // MARK: - Poll: Throttle

  @Test(arguments: [
    ("30", Duration.seconds(30)),
    // Absent, unreadable, or non-positive: honored as the pinned interval rather than as a spin.
    ("", ChatGPTProviderMetadata.defaultPollInterval),
    ("soon", ChatGPTProviderMetadata.defaultPollInterval),
    ("0", ChatGPTProviderMetadata.defaultPollInterval),
    ("-5", ChatGPTProviderMetadata.defaultPollInterval),
    // Bounded: a wait no login window could ever spend is cut back to the window itself.
    ("999999", ChatGPTProviderMetadata.maximumLoginWait),
  ])
  func pollReturnsATypedThrottleWithABoundedRetryAfter(
    header: String,
    expected: Duration
  ) async throws {
    // given
    let headers = header.isEmpty ? [:] : ["Retry-After": header]
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(429, #"{"error":"slow_down"}"#, headers: headers)
    )

    // when
    let result = try await OAuthFixture.client(http)
      .pollOnce(device: OAuthFixture.device, timeout: .seconds(30))

    // then
    #expect(result == .throttled(retryAfter: expected))
  }

  @Test func aThrottledTokenRequestCarriesItsRetryAfterAsATypedFailure() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(429, "{}", headers: ["Retry-After": "12"])
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    #expect(failure == .throttled(retryAfter: .seconds(12)))
  }

  // MARK: - Poll: Grant

  @Test func pollReturnsTheGrantTheServerIssued() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(
        200,
        #"{"authorization_code":"auth-code-value","code_verifier":"code-verifier-value"}"#
      )
    )

    // when
    let result = try await OAuthFixture.client(http)
      .pollOnce(device: OAuthFixture.device, timeout: .seconds(30))

    // then
    #expect(result == .granted(OAuthFixture.grant))
  }

  @Test(arguments: [
    // Missing either half.
    #""code_verifier":"code-verifier-value""#,
    #""authorization_code":"auth-code-value""#,
    // Empty.
    #""authorization_code":"","code_verifier":"code-verifier-value""#,
    #""authorization_code":"auth-code-value","code_verifier":"""#,
    // A control byte in a value the exchange would put straight into a form.
    #""authorization_code":"code\u0007","code_verifier":"code-verifier-value""#,
    // Wrong JSON type.
    #""authorization_code":["auth-code-value"],"code_verifier":"code-verifier-value""#,
  ])
  func pollRefusesAnUnusableGrant(fields: String) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(200, OAuthFixture.json(fields))
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).pollOnce(
        device: OAuthFixture.device,
        timeout: .seconds(30)
      )
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  @Test func pollRefusesAGrantValuePastItsByteBound() async throws {
    // given
    let oversized = String(
      repeating: "c",
      count: ChatGPTProviderMetadata.maximumGrantValueBytes + 1
    )
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(
          #""authorization_code":"\#(oversized)","code_verifier":"code-verifier-value""#
        )
      )
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).pollOnce(
        device: OAuthFixture.device,
        timeout: .seconds(30)
      )
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  // MARK: - Exchange: Form Shape

  @Test func exchangePostsTheDeterministicPercentEncodedForm() async throws {
    // given
    let grant = ChatGPTAuthorizationGrant(
      authorizationCode: "code with space&amp",
      codeVerifier: "verifier/+=~-_.plain"
    )
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, #"{"access_token":"access-token-value","expires_in":3600}"#)
    )

    // when
    _ = try await OAuthFixture.client(http).exchange(grant: grant, timeout: .seconds(30))

    // then
    let sent = try #require(await http.requests.first)
    #expect(sent.method == .post)
    #expect(sent.url == ChatGPTProviderMetadata.tokenURL)
    #expect(sent.headers["Content-Type"] == "application/x-www-form-urlencoded")
    // The redirect URI is spelled out in its encoded form on purpose: rebuilding it from the
    // constant would assert the encoder against itself.
    #expect(
      sent.bodyText
        == "grant_type=authorization_code"
        + "&code=code%20with%20space%26amp"
        + "&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"
        + "&client_id=\(ChatGPTProviderMetadata.clientID)"
        + "&code_verifier=verifier%2F%2B%3D~-_.plain"
    )
  }

  @Test func refreshPostsTheRefreshFormWithThePinnedClientID() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, #"{"access_token":"access-token-value","expires_in":3600}"#)
    )

    // when
    _ = try await OAuthFixture.client(http)
      .refresh(refreshToken: "refresh/token+value", timeout: .seconds(30))

    // then
    let sent = try #require(await http.requests.first)
    #expect(sent.url == ChatGPTProviderMetadata.tokenURL)
    #expect(sent.headers["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(
      sent.bodyText
        == "grant_type=refresh_token"
        + "&refresh_token=refresh%2Ftoken%2Bvalue"
        + "&client_id=\(ChatGPTProviderMetadata.clientID)"
    )
  }

  // MARK: - Ingress Validation

  @Test(arguments: [
    // Past the grant bound.
    String(repeating: "c", count: ChatGPTProviderMetadata.maximumGrantValueBytes + 1),
    // A control byte no form field may carry.
    "code\u{1b}[31m",
    "",
  ])
  func exchangeRefusesAnUnusableGrantWithoutReachingTheWire(code: String) async throws {
    // given
    let http = RecordingHTTPExecutor()
    let grant = ChatGPTAuthorizationGrant(
      authorizationCode: code,
      codeVerifier: OAuthFixture.codeVerifier
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: grant, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
    let requests = await http.requests
    #expect(requests.isEmpty)
  }

  @Test(arguments: [
    String(repeating: "r", count: ChatGPTProviderMetadata.maximumTokenBytes + 1),
    "refresh token with space",
    "refresh\u{0}null",
    "",
  ])
  func refreshRefusesAnUnsafeRefreshTokenWithoutReachingTheWire(token: String) async throws {
    // given
    let http = RecordingHTTPExecutor()

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).refresh(refreshToken: token, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
    let requests = await http.requests
    #expect(requests.isEmpty)
  }

  // MARK: - Token Safety Gate

  /// The gate the rest of the credential path rests on. Header composition downstream drops the
  /// access token straight into `Bearer` without re-checking it, so a token that is empty, bears
  /// whitespace or a control byte, or is not ASCII must never leave this seam as a pair.
  @Test(arguments: [
    // Empty — the value that composes to a bare "Bearer ".
    #""access_token":"""#,
    // Whitespace, which is what lets a value fold a header of its own in behind the bearer.
    #""access_token":"tok en""#,
    #""access_token":"tok\r\nX-Injected: yes""#,
    #""access_token":"\ttoken""#,
    // Control bytes.
    #""access_token":"tok\u0000null""#,
    #""access_token":"tok\u001b[31m""#,
    // Not ASCII.
    #""access_token":"tokén""#,
    // Wrong JSON type, or absent entirely.
    #""access_token":42"#,
    #""access_token":null"#,
    #""not_a_token":"whatever""#,
  ])
  func anUnsafeAccessTokenNeverBecomesATokenPair(field: String) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, OAuthFixture.json(#"\#(field),"expires_in":3600"#))
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  @Test func anAccessTokenPastItsByteBoundNeverBecomesATokenPair() async throws {
    // given
    let oversized = String(repeating: "a", count: ChatGPTProviderMetadata.maximumTokenBytes + 1)
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(#""access_token":"\#(oversized)","expires_in":3600"#)
      )
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  /// Proves the gate rejects for the reason it claims. The same request shape, carrying a token that
  /// is merely long rather than unsafe, is accepted — so a rejection above is the guard talking and
  /// not the decoder failing on every large body it is handed.
  @Test func aHeaderSafeAccessTokenSittingOnItsByteBoundBecomesATokenPair() async throws {
    // given
    let atBound = String(repeating: "a", count: ChatGPTProviderMetadata.maximumTokenBytes)
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(#""access_token":"\#(atBound)","expires_in":3600"#)
      )
    )

    // when
    let pair = try await OAuthFixture.client(http).exchange(
      grant: OAuthFixture.grant,
      timeout: .seconds(30)
    )

    // then
    #expect(pair.accessToken == atBound)
  }

  @Test(arguments: [
    #""refresh_token":"refresh token""#,
    #""refresh_token":"refresh\u0000null""#,
    #""refresh_token":"refreshé""#,
    #""refresh_token":"""#,
    #""refresh_token":42"#,
  ])
  func anUnsafeRotatedRefreshTokenNeverBecomesATokenPair(field: String) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(#""access_token":"access-token-value","expires_in":3600,\#(field)"#)
      )
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  // MARK: - Token Pair: Expiry

  @Test(arguments: [
    (#""expires_in":3600"#, 3600),
    (#""expires_in":"3600""#, 3600),
    (#""expires_in":1"#, 1),
  ])
  func expiryComesFromAPositiveExpiresInMeasuredOnTheInjectedWallDate(
    field: String,
    seconds: Int
  ) async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, OAuthFixture.json(#""access_token":"access-token-value",\#(field)"#))
    )

    // when
    let pair = try await OAuthFixture.client(http).exchange(
      grant: OAuthFixture.grant,
      timeout: .seconds(30)
    )

    // then
    #expect(pair.expiresAt == OAuthFixture.wallNow.addingTimeInterval(TimeInterval(seconds)))
  }

  @Test(arguments: [
    // Absent.
    "",
    // Present, but never a usable duration.
    #","expires_in":0"#,
    #","expires_in":-1"#,
    #","expires_in":"soon""#,
    #","expires_in":1.5"#,
  ])
  func expiryFallsBackToTheAccessTokensExpClaim(field: String) async throws {
    // given
    let expiry = Int(OAuthFixture.wallNow.timeIntervalSince1970) + 900
    let token = OAuthFixture.token(expiringAt: expiry)
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, OAuthFixture.json(#""access_token":"\#(token)"\#(field)"#))
    )

    // when
    let pair = try await OAuthFixture.client(http).exchange(
      grant: OAuthFixture.grant,
      timeout: .seconds(30)
    )

    // then
    #expect(pair.expiresAt == Date(timeIntervalSince1970: TimeInterval(expiry)))
  }

  @Test func aPositiveExpiresInOutranksTheExpClaim() async throws {
    // given
    let token = OAuthFixture.token(
      expiringAt: Int(OAuthFixture.wallNow.timeIntervalSince1970) + 99_999
    )
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, OAuthFixture.json(#""access_token":"\#(token)","expires_in":60"#))
    )

    // when
    let pair = try await OAuthFixture.client(http).exchange(
      grant: OAuthFixture.grant,
      timeout: .seconds(30)
    )

    // then
    #expect(pair.expiresAt == OAuthFixture.wallNow.addingTimeInterval(60))
  }

  @Test func aTokenWithNoUsableFutureExpiryIsMalformedRatherThanStored() async throws {
    // given
    // No expires_in, and an access token carrying no readable exp claim of its own.
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, OAuthFixture.json(#""access_token":"access-token-value""#))
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  @Test func anExpClaimAlreadyInThePastIsMalformedRatherThanStored() async throws {
    // given
    let token = OAuthFixture.token(expiringAt: Int(OAuthFixture.wallNow.timeIntervalSince1970) - 1)
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(200, OAuthFixture.json(#""access_token":"\#(token)""#))
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }

  // MARK: - Token Pair: Rotation

  @Test func aRefreshResponseThatRotatesNoTokenReportsNoneRatherThanAnEmptyOne() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(#""access_token":"access-token-value","expires_in":60"#)
      )
    )

    // when
    let pair = try await OAuthFixture.client(http)
      .refresh(refreshToken: OAuthFixture.refreshToken, timeout: .seconds(30))

    // then
    #expect(pair.refreshToken == nil)
  }

  @Test func aRotatedRefreshTokenIsCarriedBack() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(
          #""access_token":"access-token-value","refresh_token":"rotated-value","expires_in":60"#
        )
      )
    )

    // when
    let pair = try await OAuthFixture.client(http)
      .refresh(refreshToken: OAuthFixture.refreshToken, timeout: .seconds(30))

    // then
    #expect(pair.refreshToken == "rotated-value")
  }

  // MARK: - Bodies

  @Test func aSuccessBodyPastTheReadCapFailsRatherThanArrivingShort() async throws {
    // given
    let filler = String(repeating: "x", count: ChatGPTProviderMetadata.maximumAuthResponseBytes)
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(
        200,
        OAuthFixture.json(
          #""access_token":"access-token-value","expires_in":60,"pad":"\#(filler)""#
        )
      )
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    #expect(failure?.isTransport == true)
  }

  @Test func anErrorBodyIsReadAndReportedNoWiderThanTheDiagnosticCap() async throws {
    // given
    let oversized = String(
      repeating: "e",
      count: ChatGPTProviderMetadata.maximumDiagnosticBytes * 4
    )
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(400, oversized)
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }

    // then
    let sent = try #require(await http.requests.first)
    #expect(sent.selectedBodyCap == ChatGPTProviderMetadata.maximumDiagnosticBytes)
    let detail = try #require(failure?.detail)
    #expect(detail.utf8.count <= ChatGPTProviderMetadata.maximumDiagnosticBytes)
  }

  @Test func aRemoteDiagnosticIsSanitizedAndRedactedBeforeItCanBeShown() async throws {
    // given
    // Remote text that repaints the terminal it lands on and quotes the credential back at us.
    let hostile = "\u{1b}[31mdenied\u{1b}[0m for \(OAuthFixture.refreshToken)\nline two"
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.tokenURL,
      OAuthFixture.result(400, hostile)
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http)
        .refresh(refreshToken: OAuthFixture.refreshToken, timeout: .seconds(30))
    }

    // then
    let detail = try #require(failure?.detail)
    #expect(detail.contains(OAuthFixture.refreshToken) == false)
    #expect(detail.contains("\u{1b}") == false)
    #expect(detail.contains("\n") == false)
    #expect(detail.contains("denied"))
  }

  @Test func aPollDiagnosticNeverQuotesTheDeviceAuthIDBack() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.devicePollURL,
      OAuthFixture.result(400, "unknown device \(OAuthFixture.deviceAuthID) rejected")
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).pollOnce(
        device: OAuthFixture.device,
        timeout: .seconds(30)
      )
    }

    // then
    let detail = try #require(failure?.detail)
    #expect(detail.contains(OAuthFixture.deviceAuthID) == false)
    #expect(detail.contains("rejected"))
  }

  // MARK: - Transport and Cancellation

  @Test func aTransportFailureIsReportedAsRetryableTransport() async throws {
    // given
    let http = FailingHTTP {
      HTTPTransportFailure(disposition: .mayHaveBeenSent, safeMessage: "connection reset")
    }

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))
    }

    // then
    #expect(failure?.isTransport == true)
    #expect(failure?.detail?.contains("connection reset") == true)
  }

  /// Cancellation is the owner walking away, not the vendor failing. Sanitizing it into a transport
  /// error would make an abandoned login look retryable to every caller above this seam.
  @Test func cancellationIsPreservedRatherThanSanitizedIntoATransportFailure() async throws {
    // given
    let client = OAuthFixture.client(FailingHTTP { CancellationError() })

    // when / then
    await #expect(throws: CancellationError.self) {
      try await client.requestDeviceCode(timeout: .seconds(30))
    }
    await #expect(throws: CancellationError.self) {
      try await client.pollOnce(device: OAuthFixture.device, timeout: .seconds(30))
    }
    await #expect(throws: CancellationError.self) {
      try await client.exchange(grant: OAuthFixture.grant, timeout: .seconds(30))
    }
    await #expect(throws: CancellationError.self) {
      try await client.refresh(refreshToken: OAuthFixture.refreshToken, timeout: .seconds(30))
    }
  }

  @Test func aResponseThatIsNotJSONAtAllIsMalformed() async throws {
    // given
    let http = OAuthFixture.executor(
      ChatGPTProviderMetadata.userCodeURL,
      OAuthFixture.result(200, "<html>not json</html>")
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await OAuthFixture.client(http).requestDeviceCode(timeout: .seconds(30))
    }

    // then
    #expect(failure?.isMalformed == true)
  }
}
