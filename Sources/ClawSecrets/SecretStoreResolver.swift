import ClawCore
import Foundation

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

/// Fail-closed backend selection. If **either** `secrets.enc` or `secret.key`
/// is present, the encrypted backend is **required** (both must exist and decrypt, else exit 11) — we
/// never silently fall back to env when an encrypted setup is partially present. The env fallback
/// (+ warn) is used **only** when *neither* encrypted artifact exists.
public enum SecretStoreResolver {
  public static func resolve(
    stateRoot: URL,
    environment: [String: String],
    warn: @escaping @Sendable (String) -> Void = EnvSecretStore.defaultWarn
  ) -> ResolvedSecretStore {
    let paths = SecretStatePaths(stateRoot: stateRoot)
    let hasKey = SecureFilePublisher.entryExists(at: paths.key)
    let hasEnvelope = SecureFilePublisher.entryExists(at: paths.runtimeEnvelope)

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
}

// MARK: - Doctor row

extension SecretStoreResolver {
  /// The doctor "secrets" row: backend label + an `ok` flag, computed by a **real decrypt without
  /// booting**. Used by `doctor --check-config` to validate decrypt early.
  public static func doctorRow(
    stateRoot: URL,
    environment: [String: String]
  ) -> DoctorRowResult {
    let resolution = resolve(
      stateRoot: stateRoot,
      environment: environment,
      warn: { _ in }
    )

    do {
      _ = try resolution.store.loadSecrets()
      switch resolution.backend {
      case .encrypted:
        return DoctorRowResult(value: "backend=encrypted", ok: true)
      case .env:
        return DoctorRowResult(value: "backend=env (WARN: plaintext)", ok: true)
      }
    } catch {
      return DoctorRowResult(value: "FAIL: \(error)", ok: false)
    }
  }
}
