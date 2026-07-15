import ClawCore
import Foundation
import Testing

@testable import ClawAuth

/// The nested claim the vendor carries the account under. Spelled out here rather than imported
/// from the source under test, so a silent rename of the production claim name fails these tests
/// instead of moving with them.
private let accountClaimName = "https://api.openai.com/auth"

/// Builds JWT-shaped strings from claim payloads. Signatures are never verified by the parser under
/// test, so the third segment is arbitrary text rather than a real MAC. Module-scoped, so the suites
/// that need a token with a given claim share one notion of what a token looks like.
enum TokenBuilder {
  static func segment(_ json: String) -> String {
    base64URL(Data(json.utf8))
  }

  static func base64URL(_ data: Data) -> String {
    standardBase64(data)
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }

  /// Unpadded base64 in the *standard* alphabet, which differs from base64url only in the two
  /// URL-unsafe characters. Padding is dropped so the two forms differ in nothing else.
  static func standardBase64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  static func token(payload: String) -> String {
    "\(segment(#"{"alg":"none"}"#)).\(segment(payload)).signature-not-verified"
  }

  static func token(rawPayloadSegment: String) -> String {
    "\(segment(#"{"alg":"none"}"#)).\(rawPayloadSegment).signature-not-verified"
  }

  /// A payload whose decoded size is `bytes`, padded with a filler claim so the JSON stays valid.
  static func payload(paddedTo bytes: Int, accountID: String) -> String {
    let prefix = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)"},"pad":""#
    let suffix = #""}"#
    let fillerCount = bytes - prefix.utf8.count - suffix.utf8.count
    return prefix + String(repeating: "x", count: fillerCount) + suffix
  }
}

@Suite struct ChatGPTTokenMetadataTests {
  // MARK: - Positive Extraction

  @Test func extractReadsExpiryAndAccountFromAWellFormedToken() {
    // given
    let token = TokenBuilder.token(
      payload: #"{"exp":1893456000,"\#(accountClaimName)":{"chatgpt_account_id":"acct-123"}}"#
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
    #expect(metadata.accountID == "acct-123")
  }

  @Test(arguments: [
    (#"{"exp":1893456000}"#, 1_893_456_000.0),
    (#"{"exp":"1893456000"}"#, 1_893_456_000.0),
    (#"{"exp":1}"#, 1.0),
  ])
  func extractAcceptsNumericAndDecimalStringExpiry(payload: String, expected: TimeInterval) {
    // given
    let token = TokenBuilder.token(payload: payload)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == Date(timeIntervalSince1970: expected))
  }

  @Test func extractReadsAnAccountIdWithoutAnExpiryClaim() {
    // given
    let token = TokenBuilder.token(
      payload: #"{"\#(accountClaimName)":{"chatgpt_account_id":"solo-account"}}"#
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == nil)
    #expect(metadata.accountID == "solo-account")
  }

  @Test func extractReadsAnExpiryWithoutAnAccountClaim() {
    // given
    let token = TokenBuilder.token(payload: #"{"exp":1893456000,"sub":"user"}"#)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
    #expect(metadata.accountID == nil)
  }

  @Test func extractAcceptsAnAccountIdExactlyAtThe256ByteBar() {
    // given
    let exact = String(repeating: "a", count: 256)
    let token = TokenBuilder.token(
      payload: #"{"\#(accountClaimName)":{"chatgpt_account_id":"\#(exact)"}}"#
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.accountID == exact)
  }

  @Test func extractAcceptsAPayloadExactlyAtThe64KiBBound() {
    // given
    let payload = TokenBuilder.payload(paddedTo: 65_536, accountID: "large-but-legal")
    let token = TokenBuilder.token(payload: payload)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(payload.utf8.count == 65_536)
    #expect(metadata.accountID == "large-but-legal")
  }

  // MARK: - Payload Bound

  @Test func extractRejectsAPayloadOneByteOverThe64KiBBound() {
    // given
    let payload = TokenBuilder.payload(paddedTo: 65_537, accountID: "over-the-bound")
    let token = TokenBuilder.token(payload: payload)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(payload.utf8.count == 65_537)
    #expect(metadata == ChatGPTTokenMetadata(expiresAt: nil, accountID: nil))
  }

  @Test func extractRejectsAMultiMegabytePayload() {
    // given
    let payload = TokenBuilder.payload(paddedTo: 4_000_000, accountID: "huge")
    let token = TokenBuilder.token(payload: payload)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.accountID == nil)
    #expect(metadata.expiresAt == nil)
  }

  // MARK: - Malformed Structure

  @Test(arguments: [
    "",
    "onlyonesegment",
    "two.segments",
    "four.segments.are.wrong",
    ".",
    "..",
    "header..signature",
    "header.<not base64url>.signature",
    // A length that is impossible for any base64 encoding.
    "header.A.signature",
    "header.=.signature",
  ])
  func extractYieldsEmptyMetadataForStructurallyInvalidTokens(token: String) {
    // given / when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata == ChatGPTTokenMetadata(expiresAt: nil, accountID: nil))
  }

  @Test(arguments: [
    "not json at all",
    "{",
    #"{"exp":}"#,
    "[]",
    #""a string payload""#,
    "42",
    "null",
  ])
  func extractYieldsEmptyMetadataForPayloadsThatAreNotJsonObjects(payload: String) {
    // given
    let token = TokenBuilder.token(payload: payload)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata == ChatGPTTokenMetadata(expiresAt: nil, accountID: nil))
  }

  // MARK: - Base64url Strictness

  /// A payload whose two base64 alphabets genuinely disagree. Most JSON encodes identically under
  /// both, which would make a strictness test vacuous; the `?` forces a 63 sextet, so the standard
  /// form carries `/` exactly where the base64url form carries `_`.
  static let divergentPayload = #"""
    {"exp":1893456000,"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"},"pad":"?"}
    """#

  @Test func extractReadsAPayloadEncodedInBase64url() {
    // given
    let segment = TokenBuilder.base64URL(Data(Self.divergentPayload.utf8))
    let token = TokenBuilder.token(rawPayloadSegment: segment)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(segment.contains("_"))
    #expect(metadata.accountID == "acct-123")
    #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
  }

  @Test func extractRejectsTheSamePayloadEncodedInStandardBase64() {
    // given
    // The identical bytes, in the wrong alphabet. Decoding this leniently would succeed and yield
    // a perfectly readable account, so only a strict alphabet check can turn it away.
    let segment = TokenBuilder.standardBase64(Data(Self.divergentPayload.utf8))
    let token = TokenBuilder.token(rawPayloadSegment: segment)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(segment.contains("/"))
    #expect(segment != TokenBuilder.base64URL(Data(Self.divergentPayload.utf8)))
    #expect(metadata == ChatGPTTokenMetadata(expiresAt: nil, accountID: nil))
  }

  @Test func extractYieldsEmptyMetadataForAPayloadThatIsNotValidUtf8() {
    // given
    let invalidUTF8 = Data([0xFF, 0xFE, 0xFD, 0xFC])
    let token = TokenBuilder.token(rawPayloadSegment: TokenBuilder.base64URL(invalidUTF8))

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata == ChatGPTTokenMetadata(expiresAt: nil, accountID: nil))
  }

  // MARK: - Rejected Expiry Claims

  @Test(arguments: [
    #"{"exp":0}"#,
    #"{"exp":-1}"#,
    #"{"exp":1893456000.5}"#,
    #"{"exp":"soon"}"#,
    #"{"exp":""}"#,
    #"{"exp":true}"#,
    #"{"exp":null}"#,
    #"{"exp":[1893456000]}"#,
    #"{"exp":{"at":1893456000}}"#,
    #"{"exp":1e400}"#,
  ])
  func extractOmitsAnUnusableExpiryClaim(payload: String) {
    // given
    let token = TokenBuilder.token(payload: payload)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == nil)
  }

  // MARK: - Rejected Account Claims

  @Test(arguments: [
    // The nested auth claim is absent entirely.
    #"{"sub":"user"}"#,
    // The claim is present but is not an object.
    #"{"\#(accountClaimName)":"acct-123"}"#,
    #"{"\#(accountClaimName)":["acct-123"]}"#,
    #"{"\#(accountClaimName)":null}"#,
    // The account key is absent from an otherwise valid claim object.
    #"{"\#(accountClaimName)":{"other":"value"}}"#,
    // The account value is present but is not a string.
    #"{"\#(accountClaimName)":{"chatgpt_account_id":42}}"#,
    #"{"\#(accountClaimName)":{"chatgpt_account_id":null}}"#,
    // An empty account value must not become an empty header.
    #"{"\#(accountClaimName)":{"chatgpt_account_id":""}}"#,
    // The account claim must not be read from the payload root.
    #"{"chatgpt_account_id":"acct-123"}"#,
    // A look-alike claim name must not be accepted.
    #"{"https://api.openai.com/AUTH":{"chatgpt_account_id":"acct-123"}}"#,
    #"{"https://api.openai.com/auth/":{"chatgpt_account_id":"acct-123"}}"#,
  ])
  func extractOmitsAMissingOrMalformedAccountClaim(payload: String) {
    // given
    let token = TokenBuilder.token(payload: payload)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.accountID == nil)
  }

  @Test(arguments: [
    "acct with space",
    "acct\\twith-tab",
    "acct\\nwith-newline",
    "acct\\u0000with-nul",
    "acct\\u001b[31m",
    "acct-é-non-ascii",
    " leading-space",
    "trailing-space ",
  ])
  func extractOmitsAnAccountIdThatCannotSafelyBecomeAHeaderValue(accountID: String) {
    // given
    let token = TokenBuilder.token(
      payload: #"{"\#(accountClaimName)":{"chatgpt_account_id":"\#(accountID)"}}"#
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.accountID == nil)
  }

  @Test func extractOmitsAnAccountIdOneByteOverThe256ByteBar() {
    // given
    let oversized = String(repeating: "a", count: 257)
    let token = TokenBuilder.token(
      payload: #"{"\#(accountClaimName)":{"chatgpt_account_id":"\#(oversized)"}}"#
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.accountID == nil)
  }

  // MARK: - Independence Of Claims

  @Test func aRejectedAccountClaimDoesNotDiscardAUsableExpiry() {
    // given
    // A malformed account is not a credential failure; the expiry beside it must still be read.
    let token = TokenBuilder.token(
      payload: #"""
        {"exp":1893456000,"\#(accountClaimName)":{"chatgpt_account_id":"bad account"}}
        """#
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
    #expect(metadata.accountID == nil)
  }

  @Test func aRejectedExpiryClaimDoesNotDiscardAUsableAccount() {
    // given
    let token = TokenBuilder.token(
      payload: #"{"exp":"never","\#(accountClaimName)":{"chatgpt_account_id":"acct-9"}}"#
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == nil)
    #expect(metadata.accountID == "acct-9")
  }
}
