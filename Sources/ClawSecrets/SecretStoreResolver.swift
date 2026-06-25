import ClawCore
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Which backend was selected — surfaced to doctor.
public enum SecretBackend: String, Sendable, Equatable {
  case encrypted
  case env
}

public struct ResolvedSecretStore: Sendable {
  public let store: any SecretStore
  public let backend: SecretBackend

  public init(store: any SecretStore, backend: SecretBackend) {
    self.store = store
    self.backend = backend
  }
}

/// Fail-closed backend selection (spec §3.2, review #9). If **either** `secrets.enc` or `secret.key`
/// is present, the encrypted backend is **required** (both must exist and decrypt, else exit 11) — we
/// never silently fall back to env when an encrypted setup is partially present. The env fallback
/// (+ warn) is used **only** when *neither* encrypted artifact exists.
public enum SecretStoreResolver {
  public static func resolve(
    stateRoot: URL,
    environment: [String: String],
    warn: @escaping @Sendable (String) -> Void = EnvSecretStore.defaultWarn
  ) -> ResolvedSecretStore {
    let hasKey = entryExists(at: stateRoot.appendingPathComponent(SecretFile.key))
    let hasEnvelope = entryExists(at: stateRoot.appendingPathComponent(SecretFile.envelope))

    if hasKey || hasEnvelope {
      return ResolvedSecretStore(
        store: EncryptedFileSecretStore(stateRoot: stateRoot),
        backend: .encrypted
      )
    }

    return ResolvedSecretStore(
      store: EnvSecretStore(environment: environment, warn: warn),
      backend: .env
    )
  }

  /// `lstat` (not `stat` / `FileManager.fileExists`) so a dangling symlink counts as present —
  /// a broken symlink entry still forces the encrypted backend rather than a silent env fallback.
  private static func entryExists(at url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
  }
}
