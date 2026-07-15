import Foundation

// MARK: - Authorization

/// Identifies the credential snapshot one request authorized with. Rejection is matched against it,
/// so a late failure from an older request cannot invalidate a newer token. It is process-local:
/// login runs only while the daemon is stopped, so nothing has to survive a restart.
public struct LLMCredentialGeneration: Sendable, Hashable, Equatable {
  public let value: UInt64

  public init(value: UInt64) {
    self.value = value
  }

  /// The generation of a source that never rotates. A refreshable source starts above this, so a
  /// constant generation can never be mistaken for a snapshot that could go stale.
  public static let zero = LLMCredentialGeneration(value: 0)
}

/// What a source contributes to one request: the credential-dependent headers, the exact secret
/// values a redactor must scrub before anything is logged or shown, and the snapshot they came from.
public struct LLMRequestAuthorization: Sendable, Equatable {
  public let headers: [String: String]
  public let redactionValues: [String]
  public let generation: LLMCredentialGeneration

  public init(
    headers: [String: String],
    redactionValues: [String],
    generation: LLMCredentialGeneration
  ) {
    self.headers = headers
    self.redactionValues = redactionValues
    self.generation = generation
  }
}

/// Why a caller is handing a credential back. `refresh` follows the first clean 401;
/// `authenticationRequired` follows the retry's second and latches a refreshable source terminally,
/// so a later turn cannot start another refresh loop.
public enum LLMCredentialRejection: Sendable, Equatable {
  case refresh
  case authenticationRequired
}

/// Where authorization comes from, resolved per request. Keeping it off `LLMProvider` is what stops
/// an unrelated wire adapter from having to learn about OAuth grants or subscription accounts.
public protocol LLMCredentialSource: Sendable {
  func authorization() async throws -> LLMRequestAuthorization

  /// Generation-aware by contract: a source changes state only if `generation` is still current.
  func reject(generation: LLMCredentialGeneration, disposition: LLMCredentialRejection) async

  /// The lifecycle's commit point — a source with an unpublished rotation finishes it here.
  func shutdown() async throws
}

// MARK: - Durable credentials

/// A stored OAuth pair. `profileID` is a random local UUID minted after a successful login, never
/// vendor-derived: refresh preserves it and re-login mints a new one, which is what gives opaque
/// provider state a stable provenance boundary across restarts without exposing an account.
public struct StoredOAuthCredential: Sendable, Equatable, Codable {
  public let profileID: UUID
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Date

  public init(profileID: UUID, accessToken: String, refreshToken: String, expiresAt: Date) {
    self.profileID = profileID
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}

/// A closed, redaction-safe taxonomy for the credential store. It is closed on purpose: a raw
/// `Crypto`, `POSIX`, or Foundation error carries paths and key material in its description, so
/// none may cross this seam — the same rule `StoreError` enforces at the GRDB seam.
public enum LLMCredentialStoreError: Error, Sendable, Equatable {
  case missingRuntimeKey
  case insecureStorage
  case malformedStorage
  case unsupportedVersion
  case oversizedStorage
  case publicationFailed
  /// A publication that neither provably landed nor provably did not. It is distinct from
  /// `publicationFailed` because a caller must not retry it as though nothing was written.
  case commitUncertain
}

/// Durable storage for one provider's credential. Typed throws keep the closed taxonomy above at
/// the seam rather than trusting every implementation to remember to map its errors.
public protocol LLMCredentialStore: Sendable {
  func load(providerID: LLMProviderID) throws(LLMCredentialStoreError) -> StoredOAuthCredential?
  func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError)
  func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError)
}
