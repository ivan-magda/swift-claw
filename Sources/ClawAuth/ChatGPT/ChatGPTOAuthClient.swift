import ClawCore
import Foundation

/// The ChatGPT device-and-token OAuth wire client: one request per method, one bounded request and
/// decode path, and no clock of its own.
///
/// Nothing downstream re-checks what this returns — header composition drops the access token
/// straight into a `Bearer` — so every value leaving here has already cleared the bounds a header
/// and a terminal impose. That makes this the ingress gate for the whole credential path, refresh
/// included, and the reason a token that cannot be a header never becomes a `ChatGPTTokenPair`.
///
/// The only time it knows is the injected wall date a token's expiry is measured against. Waiting,
/// deadlines, and how long a login may run belong to the caller that owns a monotonic clock; this
/// type accepts a relative timeout and never decides one.
public struct ChatGPTOAuthClient: Sendable, ChatGPTOAuthRefreshing, ChatGPTOAuthExchanging {
  private let http: any HTTPExecuting
  private let wallDate: @Sendable () -> Date

  public init(
    http: any HTTPExecuting,
    wallDate: @escaping @Sendable () -> Date
  ) {
    self.http = http
    self.wallDate = wallDate
  }

  /// Asks the vendor to start a device authorization.
  public func requestDeviceCode(timeout: Duration) async throws -> ChatGPTDeviceCode {
    let body = try Self.jsonBody([Wire.clientID: ChatGPTProviderMetadata.clientID])
    let response = try await send(
      to: ChatGPTProviderMetadata.userCodeURL,
      contentType: Wire.jsonContentType,
      body: body,
      timeout: timeout,
      redacting: []
    )
    return try Self.deviceCode(from: Self.successFields(of: response, redacting: []))
  }

  /// Asks once whether the owner has approved the device yet.
  ///
  /// Both statuses the vendor answers a waiting device with are ordinary "not yet" — 403 alongside
  /// the 404 the endpoint returns before the authorization exists. Everything else is an answer, and
  /// answers are not waited on.
  public func pollOnce(
    device: ChatGPTDeviceCode,
    timeout: Duration
  ) async throws -> ChatGPTPollResult {
    // Both submitted values are redacted: a 4xx/5xx body may echo either, and either reaching a
    // diagnostic is a leak.
    let secrets = [device.deviceAuthID, device.userCode]
    let body = try Self.jsonBody([
      Wire.deviceAuthID: device.deviceAuthID,
      Wire.userCode: device.userCode,
    ])
    let response = try await send(
      to: ChatGPTProviderMetadata.devicePollURL,
      contentType: Wire.jsonContentType,
      body: body,
      timeout: timeout,
      redacting: secrets
    )

    if Wire.pendingStatuses.contains(response.statusCode) {
      return .pending
    }
    if response.statusCode == Wire.throttledStatus {
      // A poll always has a delay to honor: with nothing usable named, the pinned interval is the
      // one wait that is certainly not a spin.
      return .throttled(
        retryAfter: Self.retryAfter(of: response) ?? ChatGPTProviderMetadata.defaultPollInterval
      )
    }

    let fields = try Self.successFields(of: response, redacting: secrets)
    return .granted(try Self.grant(from: fields))
  }

  /// Spends an approved grant for the credential pair it stands for.
  public func exchange(
    grant: ChatGPTAuthorizationGrant,
    timeout: Duration
  ) async throws -> ChatGPTTokenPair {
    guard
      let code = ChatGPTWireValues.controlFree(
        grant.authorizationCode,
        maxBytes: ChatGPTProviderMetadata.maximumGrantValueBytes
      ),
      let verifier = ChatGPTWireValues.controlFree(
        grant.codeVerifier,
        maxBytes: ChatGPTProviderMetadata.maximumGrantValueBytes
      )
    else {
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the grant is not a value this flow can spend"
      )
    }

    let body = Self.formBody([
      (Wire.grantType, Wire.authorizationCodeGrant),
      (Wire.code, code),
      (Wire.redirectURI, ChatGPTProviderMetadata.redirectURI),
      (Wire.clientID, ChatGPTProviderMetadata.clientID),
      (Wire.codeVerifier, verifier),
    ])
    return try await tokenPair(from: body, redacting: [code, verifier], timeout: timeout)
  }

  /// Redeems a refresh token for a fresh pair.
  public func refresh(
    refreshToken: String,
    timeout: Duration
  ) async throws -> ChatGPTTokenPair {
    guard
      let token = ChatGPTWireValues.headerSafeToken(
        refreshToken,
        maxBytes: ChatGPTProviderMetadata.maximumTokenBytes
      )
    else {
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the refresh token is not a value this flow can spend"
      )
    }

    let body = Self.formBody([
      (Wire.grantType, Wire.refreshTokenGrant),
      (Wire.refreshToken, token),
      (Wire.clientID, ChatGPTProviderMetadata.clientID),
    ])
    return try await tokenPair(from: body, redacting: [token], timeout: timeout)
  }
}

// MARK: - Wire Vocabulary

private enum Wire {
  static let jsonContentType = "application/json"
  static let formContentType = "application/x-www-form-urlencoded"
  static let retryAfterHeader = "Retry-After"
  static let contentTypeHeader = "Content-Type"

  static let clientID = "client_id"
  static let deviceAuthID = "device_auth_id"
  static let userCode = "user_code"
  /// The response spelling the vendor is observed to use interchangeably with `user_code`.
  static let userCodeAlias = "usercode"
  static let interval = "interval"
  static let authorizationCode = "authorization_code"
  static let codeVerifier = "code_verifier"
  static let accessToken = "access_token"
  static let refreshToken = "refresh_token"
  static let expiresIn = "expires_in"
  static let grantType = "grant_type"
  static let code = "code"
  static let redirectURI = "redirect_uri"
  static let authorizationCodeGrant = "authorization_code"
  static let refreshTokenGrant = "refresh_token"

  /// Both mean the same thing on a device poll: keep waiting.
  static let pendingStatuses: Set<Int> = [403, 404]
  static let throttledStatus = 429
  static let timeoutStatus = 408
  static let serverErrorStatuses = 500...599
}

// MARK: - Requests

private extension ChatGPTOAuthClient {
  /// The one road to the wire. Caps both bodies at read time — the sanitizer downstream bounds what
  /// it *emits*, not what it is handed, so an unbounded body would already have been materialized by
  /// the time anything trimmed it.
  func send(
    to url: String,
    contentType: String,
    body: Data,
    timeout: Duration,
    redacting secrets: [String]
  ) async throws -> HTTPResult {
    let request = HTTPRequest(
      method: .post,
      url: url,
      headers: [Wire.contentTypeHeader: contentType],
      body: body,
      timeoutSeconds: ChatGPTProviderMetadata.transportSeconds(timeout),
      responseBodyPolicy: .buffered(
        successBytes: ChatGPTProviderMetadata.maximumAuthResponseBytes,
        errorBytes: ChatGPTProviderMetadata.maximumDiagnosticBytes
      )
    )

    return try await ChatGPTProviderMetadata.execute(
      request,
      on: http,
      redacting: secrets
    ) { detail in
      ChatGPTOAuthFailure.transport(detail: detail)
    }
  }

  static func jsonBody(_ fields: [String: String]) throws -> Data {
    // Sorted keys (via CanonicalJSON) so the body a test pins is the body every run produces.
    guard let json = CanonicalJSON.encode(fields) else {
      // A dictionary of strings has nothing in it that can fail to encode, so reaching here is a
      // defect in this file rather than anything the network or the vendor did — not a `transport`,
      // which a caller would answer by spending its retry budget on a request that cannot improve.
      throw ChatGPTOAuthFailure.malformedResponse(detail: "the request body could not be encoded")
    }
    return Data(json.utf8)
  }

  /// Field order is the caller's, and every byte outside the RFC 3986 unreserved set becomes an
  /// uppercase triplet — so the same values always produce the same bytes.
  ///
  /// Hand-rolled rather than delegated to `addingPercentEncoding(withAllowedCharacters:)`, whose
  /// sets describe what a *URL component* may hold rather than what a form field must escape: it
  /// leaves `+` alone, and a `+` inside a token would arrive at the server as a space.
  static func formBody(_ fields: [(name: String, value: String)]) -> Data {
    let encoded =
      fields
      .map { field in
        "\(percentEncoded(field.name))=\(percentEncoded(field.value))"
      }
      .joined(separator: "&")
    return Data(encoded.utf8)
  }

  static func percentEncoded(_ raw: String) -> String {
    var encoded = String.UnicodeScalarView()
    for byte in raw.utf8 {
      if isUnreserved(byte) {
        encoded.append(Unicode.Scalar(byte))
      } else {
        encoded.append(contentsOf: String(format: "%%%02X", byte).unicodeScalars)
      }
    }
    return String(encoded)
  }

  static func isUnreserved(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"),
      UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"):
      return true
    case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
      return true
    default:
      return false
    }
  }
}

// MARK: - Responses

private extension ChatGPTOAuthClient {
  /// The decoded object of a successful response, or the typed failure a non-success one stands for.
  static func successFields(
    of response: HTTPResult,
    redacting secrets: [String]
  ) throws -> [String: JSONValue] {
    guard HTTPResponseBodyPolicy.isSuccess(response.statusCode) else {
      throw failure(for: response, redacting: secrets)
    }
    guard
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: response.body),
      case .object(let fields) = decoded
    else {
      throw ChatGPTOAuthFailure.malformedResponse(detail: "the response was not a JSON object")
    }
    return fields
  }

  /// What a non-success status means to a caller, which is not the same question as what it says.
  /// The status line is folded into the diagnostic before sanitizing, so one bound covers the whole
  /// text and the part we wrote cannot be the part that gets truncated away.
  static func failure(
    for response: HTTPResult,
    redacting secrets: [String]
  ) -> ChatGPTOAuthFailure {
    // Lossy on purpose: a diagnostic body that is not valid UTF-8 is still a diagnostic, and a
    // failable read would answer a broken vendor with silence.
    // swiftlint:disable:next optional_data_string_conversion
    let body = String(decoding: response.body, as: UTF8.self)
    let detail = ChatGPTProviderMetadata.safeDiagnostic(
      "status \(response.statusCode): \(body)",
      redacting: secrets
    )

    switch response.statusCode {
    case Wire.throttledStatus:
      return .throttled(retryAfter: retryAfter(of: response))
    case Wire.timeoutStatus, Wire.serverErrorStatuses:
      return .transport(detail: detail)
    default:
      return .grantRejected(detail: detail)
    }
  }

  /// A delay the vendor named in delta-seconds, bounded by the longest wait any login could spend.
  /// Unreadable, zero, and negative values are all absent rather than coerced.
  ///
  /// The header's other RFC 7231 form, an HTTP-date, is knowingly not read and lands as absent with
  /// the rest. A caller answers absent with its own pinned interval, so the cost of the narrowing is
  /// a wait of the wrong length — never a spin — and reading dates can wait for a vendor that sends
  /// them.
  static func retryAfter(of response: HTTPResult) -> Duration? {
    guard
      let raw = response.getHeader(for: Wire.retryAfterHeader),
      let seconds = ChatGPTWireValues.positiveInteger(.string(raw))
    else {
      return nil
    }
    return min(.seconds(seconds), ChatGPTProviderMetadata.maximumLoginWait)
  }
}

// MARK: - Device Authorization Values

private extension ChatGPTOAuthClient {
  static func deviceCode(from fields: [String: JSONValue]) throws -> ChatGPTDeviceCode {
    guard
      let deviceAuthID = boundedText(
        fields[Wire.deviceAuthID],
        maxBytes: ChatGPTProviderMetadata.maximumDeviceAuthIDBytes
      ),
      let userCode = boundedText(
        fields[Wire.userCode] ?? fields[Wire.userCodeAlias],
        maxBytes: ChatGPTProviderMetadata.maximumUserCodeBytes
      )
    else {
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the device response named no usable device or user code"
      )
    }

    return ChatGPTDeviceCode(
      deviceAuthID: deviceAuthID,
      userCode: userCode,
      pollInterval: pollInterval(from: fields)
    )
  }

  static func grant(from fields: [String: JSONValue]) throws -> ChatGPTAuthorizationGrant {
    guard
      let code = boundedText(
        fields[Wire.authorizationCode],
        maxBytes: ChatGPTProviderMetadata.maximumGrantValueBytes
      ),
      let verifier = boundedText(
        fields[Wire.codeVerifier],
        maxBytes: ChatGPTProviderMetadata.maximumGrantValueBytes
      )
    else {
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the poll response named no usable authorization code or verifier"
      )
    }
    return ChatGPTAuthorizationGrant(authorizationCode: code, codeVerifier: verifier)
  }

  /// What the vendor asked for, or the pinned interval when it asked for nothing this flow can act
  /// on. How much of it is actually waited is the caller's decision, not this one's.
  static func pollInterval(from fields: [String: JSONValue]) -> Duration {
    guard
      let value = fields[Wire.interval],
      let seconds = ChatGPTWireValues.positiveInteger(value)
    else {
      return ChatGPTProviderMetadata.defaultPollInterval
    }
    return .seconds(seconds)
  }

  /// Bounded and control-free: enough to be carried as data and printed, which is all a device code
  /// or a grant is ever asked to be.
  static func boundedText(_ value: JSONValue?, maxBytes: Int) -> String? {
    guard case .string(let raw)? = value else {
      return nil
    }
    return ChatGPTWireValues.controlFree(raw, maxBytes: maxBytes)
  }
}

// MARK: - Token Pairs

private extension ChatGPTOAuthClient {
  func tokenPair(
    from body: Data,
    redacting secrets: [String],
    timeout: Duration
  ) async throws -> ChatGPTTokenPair {
    let response = try await send(
      to: ChatGPTProviderMetadata.tokenURL,
      contentType: Wire.formContentType,
      body: body,
      timeout: timeout,
      redacting: secrets
    )
    return try validatedPair(from: Self.successFields(of: response, redacting: secrets))
  }

  /// The gate. An access token becomes a header verbatim and is never inspected again, so one that
  /// is empty, bears whitespace or a control byte, is not ASCII, or outruns its bound stops here
  /// rather than composing into a `Bearer` nobody would look at twice.
  func validatedPair(from fields: [String: JSONValue]) throws -> ChatGPTTokenPair {
    guard
      case .string(let rawAccess)? = fields[Wire.accessToken],
      let accessToken = ChatGPTWireValues.headerSafeToken(
        rawAccess,
        maxBytes: ChatGPTProviderMetadata.maximumTokenBytes
      )
    else {
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the token response named no access token fit to be a header"
      )
    }

    let rotated = try Self.rotatedRefreshToken(from: fields)

    guard let expiresAt = expiry(from: fields, accessToken: accessToken) else {
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the token response named no usable future expiry"
      )
    }

    return ChatGPTTokenPair(
      accessToken: accessToken,
      refreshToken: rotated,
      expiresAt: expiresAt
    )
  }

  /// A rotated token, or none. Absent means "the one you hold still stands"; present but unusable is
  /// a failure rather than a silent fall back to the old token, because a vendor that rotated has
  /// already retired what the caller holds.
  static func rotatedRefreshToken(from fields: [String: JSONValue]) throws -> String? {
    switch fields[Wire.refreshToken] {
    case nil, .null?:
      return nil
    case .string(let raw)?:
      guard
        let token = ChatGPTWireValues.headerSafeToken(
          raw,
          maxBytes: ChatGPTProviderMetadata.maximumTokenBytes
        )
      else {
        throw ChatGPTOAuthFailure.malformedResponse(
          detail: "the token response rotated a refresh token unfit to be a header"
        )
      }
      return token
    default:
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the token response rotated a refresh token that is not a string"
      )
    }
  }

  /// The vendor's stated lifetime first, measured against the injected wall date, then the token's
  /// own `exp` claim. Nothing usable and in the future means the pair is malformed: storing it would
  /// hand a refresh loop a credential it could never schedule.
  func expiry(from fields: [String: JSONValue], accessToken: String) -> Date? {
    let now = wallDate()
    if let stated = Self.statedLifetime(from: fields) {
      return now.addingTimeInterval(stated)
    }

    guard
      let claimed = ChatGPTTokenMetadata.extract(accessToken: accessToken).expiresAt,
      claimed > now
    else {
      return nil
    }
    return claimed
  }

  /// How long the vendor says the token has, when it says anything this flow can act on.
  static func statedLifetime(from fields: [String: JSONValue]) -> TimeInterval? {
    guard
      let value = fields[Wire.expiresIn],
      let seconds = ChatGPTWireValues.positiveInteger(value)
    else {
      return nil
    }
    return TimeInterval(seconds)
  }
}
