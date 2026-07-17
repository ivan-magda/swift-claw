import ClawCore
import Foundation

/// The unverified metadata carried inside an access token.
///
/// Reading these claims is **not** authorization. The signature is never checked here — the server
/// remains the only party that decides whether a token is valid — so nothing derived from this type
/// may gate access. It exists so the daemon can schedule a refresh before a token lapses and can
/// address the account the vendor expects, and both fields are optional because a token that
/// carries neither is still a token the server may well accept.
public struct ChatGPTTokenMetadata: Sendable, Equatable {
  public let expiresAt: Date?
  public let accountID: String?

  public init(expiresAt: Date?, accountID: String?) {
    self.expiresAt = expiresAt
    self.accountID = accountID
  }

  /// Reads what it can and reports the rest as absent. This never throws and never traps: it is fed
  /// bytes the daemon did not author, and on this path a malformed token must degrade to "no
  /// metadata" rather than become an error that outranks the server's own verdict.
  public static func extract(accessToken: String) -> ChatGPTTokenMetadata {
    guard
      let payload = decodedPayload(of: accessToken),
      case .object(let claims) = payload
    else {
      return ChatGPTTokenMetadata(expiresAt: nil, accountID: nil)
    }

    return ChatGPTTokenMetadata(
      expiresAt: expiry(from: claims),
      accountID: account(from: claims)
    )
  }
}

// MARK: - Payload Decoding

private extension ChatGPTTokenMetadata {
  /// The largest decoded payload worth looking at. A token is a credential we chose to store, not
  /// arbitrary input, but it arrives over the network and is re-read on every authorization, so the
  /// work it can provoke is capped rather than trusted.
  static let maximumPayloadBytes = 64 * 1024

  /// A JWT is `header.payload.signature`. Exactly three segments — a token with more or fewer is
  /// not a shape this reads.
  static let expectedSegmentCount = 3

  static func decodedPayload(of accessToken: String) -> JSONValue? {
    let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == expectedSegmentCount else {
      return nil
    }

    guard let payload = decodingBase64URL(String(segments[1])) else {
      return nil
    }

    return try? JSONDecoder().decode(JSONValue.self, from: payload)
  }

  /// Strict base64url: the alphabet is checked before decoding, and the decoded size is computed
  /// and rejected against the cap *before* any buffer is allocated — so an oversized payload costs
  /// a length check rather than the memory it asked for. `Data(base64Encoded:)` without
  /// `.ignoreUnknownCharacters` then rejects what the alphabet check could not.
  static func decodingBase64URL(_ segment: String) -> Data? {
    guard
      segment.isEmpty == false,
      segment.unicodeScalars.allSatisfy(isBase64URLScalar),
      let decodedByteCount = decodedByteCount(ofBase64URL: segment),
      decodedByteCount <= maximumPayloadBytes
    else {
      return nil
    }

    var standard =
      segment
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    standard.append(String(repeating: "=", count: (4 - standard.count % 4) % 4))

    return Data(base64Encoded: standard)
  }

  /// The exact decoded length implied by an unpadded base64url segment, or nil for a length no
  /// base64 encoding can produce (a remainder of one leaves a byte half-encoded).
  static func decodedByteCount(ofBase64URL segment: String) -> Int? {
    let remainder = segment.count % 4
    guard remainder != 1 else {
      return nil
    }
    let wholeGroups = segment.count / 4
    let trailingBytes = remainder == 0 ? 0 : remainder - 1
    return wholeGroups * 3 + trailingBytes
  }

  static func isBase64URLScalar(_ scalar: Unicode.Scalar) -> Bool {
    ("A"..."Z").contains(scalar)
      || ("a"..."z").contains(scalar)
      || ("0"..."9").contains(scalar)
      || scalar == "-"
      || scalar == "_"
  }
}

// MARK: - Claims

private extension ChatGPTTokenMetadata {
  /// The nested claim the vendor carries subscription details under.
  static let authClaimName = "https://api.openai.com/auth"
  static let accountClaimName = "chatgpt_account_id"
  static let expiryClaimName = "exp"

  /// The bar an account value must clear to become a header: the same one every other outbound
  /// header value clears. A claim that fails it is dropped, never repaired.
  static let maximumAccountIDBytes = 256

  /// `exp` is seconds since the epoch, encoded as a number or a decimal string depending on the
  /// issuer. Reusing the wire parser is what makes a fractional or negative expiry impossible here
  /// without restating the rule.
  static func expiry(from claims: [String: JSONValue]) -> Date? {
    guard
      let claim = claims[expiryClaimName],
      let seconds = ChatGPTWireValues.positiveInteger(claim)
    else {
      return nil
    }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
  }

  static func account(from claims: [String: JSONValue]) -> String? {
    guard
      case .object(let auth)? = claims[authClaimName],
      case .string(let raw)? = auth[accountClaimName]
    else {
      return nil
    }
    return ChatGPTWireValues.headerSafeToken(raw, maxBytes: maximumAccountIDBytes)
  }
}
