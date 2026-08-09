/// A closed, redaction-safe taxonomy for every credential file sealed under the runtime key. It is
/// closed on purpose: a raw `Crypto`, `POSIX`, or Foundation error carries paths and key material in
/// its description, so none may cross this seam — the same rule `StoreError` enforces at the GRDB
/// seam.
///
/// Shared by the provider credential map and the MCP token map because both are the same file shape
/// with the same failure modes; a second copy would let one of them quietly lose a case.
public enum CredentialStoreError: Error, Sendable, Equatable {
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

extension CredentialStoreError: CustomStringConvertible {
  /// Owner-facing wording for the commands that print one of these and exit. Each case says what is
  /// wrong and what changed, because the two questions have different answers here: a failed
  /// publication left the previous credential whole, and an uncertain one did not.
  public var description: String {
    switch self {
    case .missingRuntimeKey:
      return "no runtime key in the state root; run: clawd secrets seal"
    case .insecureStorage:
      return "the credential file or the runtime key has unsafe ownership or permissions"
    case .malformedStorage:
      return "the credential file failed authentication; it is truncated, tampered with, or sealed "
        + "under another key"
    case .unsupportedVersion:
      return "the credential file was written by a newer clawd"
    case .oversizedStorage:
      return "the credential file is larger than the cap this build will read"
    case .publicationFailed:
      return "the credential file could not be written; nothing was changed"
    case .commitUncertain:
      return "the credential was written but could not be proven durable"
    }
  }
}
