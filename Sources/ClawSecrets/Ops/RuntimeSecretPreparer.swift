import ClawCore
import Foundation

/// Brings the encrypted runtime-secret backend up to a state the daemon can boot from, and returns
/// the secrets it will boot with.
///
/// `auth login` needs this because the resolver requires the encrypted backend the moment either
/// artifact exists: writing a credential envelope beside a `secret.key` that login minted on its
/// own would strand an environment-backed installation halfway. So the runtime secrets move first,
/// through the same operation `clawd secrets seal` runs, or login does not happen at all.
///
/// It performs no network work by construction — `ClawSecrets` has no HTTP client to reach for. A
/// login that cannot seal its runtime secrets must fail before it contacts a vendor, not after.
public enum RuntimeSecretPreparer {
  /// Returns runtime secrets proven decryptable from disk, sealing the environment's plaintext
  /// first if this installation has no encrypted artifacts yet. Throws before creating anything if
  /// a required secret is missing, and refuses to repair a partial encrypted setup by minting its
  /// missing half.
  public static func prepare(
    stateRoot: URL,
    environment: [String: String]
  ) throws(SecretStoreError) -> Secrets {
    try prepare(stateRoot: stateRoot, environment: environment, publisher: SecureFilePublisher())
  }

  static func prepare(
    stateRoot: URL,
    environment: [String: String],
    publisher: SecureFilePublisher
  ) throws(SecretStoreError) -> Secrets {
    // The resolver already owns the fail-closed rule for which backend a state root is on; asking
    // it keeps login and daemon startup from ever disagreeing about that.
    let resolution = SecretStoreResolver.resolve(
      stateRoot: stateRoot,
      environment: environment,
      warn: { _ in }
    )

    switch resolution.backend {
    case .encrypted:
      // A complete setup decrypts and is already authoritative; a partial one fails here with the
      // same diagnostic the daemon prints at startup.
      return try load(resolution.store)

    case .env:
      // Suppressed warning above: reading plaintext in order to encrypt it is the intent.
      let plaintext = try load(resolution.store)
      return try EncryptedFileSecretStore.seal(
        plaintext,
        stateRoot: stateRoot,
        publisher: publisher
      )
    }
  }

  /// `SecretStore.loadSecrets` cannot declare its error type, but every implementation in this
  /// module throws only `SecretStoreError` — this is where that contract is enforced rather than
  /// assumed.
  private static func load(_ store: any SecretStore) throws(SecretStoreError) -> Secrets {
    do {
      return try store.loadSecrets()
    } catch let error as SecretStoreError {
      throw error
    } catch {
      throw .unreadable("load runtime secrets")
    }
  }
}
