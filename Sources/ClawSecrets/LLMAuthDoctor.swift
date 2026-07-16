import ClawAuth
import ClawCore
import Foundation

/// The network-free `llm.auth` doctor verdict: a rendered value and whether the row passes. It mirrors
/// the secrets row's shape so doctor folds it into the report the same way.
public struct LLMAuthDoctorResult: Sendable, Equatable {
  public let value: String
  public let ok: Bool

  public init(value: String, ok: Bool) {
    self.value = value
    self.ok = ok
  }
}

/// Reports credential health for the configured LLM route with no network, refresh, or entitlement
/// check, so an owner can diagnose auth while the daemon is stopped. It reads only what is already on
/// disk: the current route reports the presence of the loaded static bearer and never opens an OAuth
/// envelope, while the ChatGPT route decrypts one stored record and classifies its expiry through the
/// same skew the live source applies.
///
/// Network-freedom is a structural property of the module graph, not a runtime guard: ClawSecrets
/// links no HTTP, OAuth-flow, or catalog module, so no code path reachable from here can cross the
/// wire. Enforce it by keeping that dependency surface closed, not by asserting on an unwired sentinel.
public enum LLMAuthDoctor {
  public static func inspect(
    route: ResolvedLLMRoute,
    staticAPIKey: String?,
    credentialStore: (any LLMCredentialStore)?,
    now: Date
  ) -> LLMAuthDoctorResult {
    let provider = "provider=\(route.descriptor.providerID)"
    switch route.descriptor.credentialMode {
    case .noneOrStaticBearer:
      return staticRow(provider: provider, staticAPIKey: staticAPIKey)
    case .managedOAuth:
      return oauthRow(provider: provider, store: credentialStore, now: now)
    }
  }

  /// Route-directed convenience: the current route never constructs a store, so `makeManagedStore`
  /// runs only for the managed OAuth route. It is the seam doctor and the daemon reporter call, which
  /// keeps the "current route opens no unused envelope" rule in one tested place.
  public static func inspect(
    route: ResolvedLLMRoute,
    staticAPIKey: String?,
    now: Date,
    makeManagedStore: () -> any LLMCredentialStore
  ) -> LLMAuthDoctorResult {
    let store: (any LLMCredentialStore)? =
      route.descriptor.credentialMode == .managedOAuth ? makeManagedStore() : nil
    return inspect(
      route: route,
      staticAPIKey: staticAPIKey,
      credentialStore: store,
      now: now
    )
  }
}

// MARK: - Current Route

private extension LLMAuthDoctor {
  /// The current route carries only a static bearer, and doctor reports its presence, never its bytes.
  /// It is always an OK row: an absent key is a legitimate no-auth configuration, not a fault.
  static func staticRow(provider: String, staticAPIKey: String?) -> LLMAuthDoctorResult {
    let mode = staticAPIKey == nil ? "none" : "static"
    return LLMAuthDoctorResult(value: "\(provider) mode=\(mode)", ok: true)
  }
}

// MARK: - ChatGPT Route

private extension LLMAuthDoctor {
  static func oauthRow(
    provider: String,
    store: (any LLMCredentialStore)?,
    now: Date
  ) -> LLMAuthDoctorResult {
    guard let store else {
      return loggedOut(provider: provider)
    }
    let stored: StoredOAuthCredential?
    do {
      stored = try store.load(providerID: ChatGPTProviderMetadata.providerID)
    } catch {
      return unreadable(provider: provider, error: error)
    }
    guard let stored else {
      return loggedOut(provider: provider)
    }
    let status = statusToken(
      ChatGPTCredentialFreshness.classify(expiresAt: stored.expiresAt, now: now)
    )
    return LLMAuthDoctorResult(value: "\(provider) mode=oauth status=\(status)", ok: true)
  }

  /// Maps the sole freshness classifier's three cases to their status tokens. Doctor never re-derives
  /// the skew: the daemon and this row read the same verdict for the same wall date.
  static func statusToken(_ freshness: ChatGPTCredentialFreshness) -> String {
    switch freshness {
    case .fresh: "fresh"
    case .expiring: "expiring"
    case .expired: "expired-refresh-on-use"
    }
  }
}

// MARK: - Failing Rows

private extension LLMAuthDoctor {
  static func loggedOut(provider: String) -> LLMAuthDoctorResult {
    LLMAuthDoctorResult(
      value: "\(provider) mode=oauth not logged in; run: clawd auth login",
      ok: false
    )
  }

  /// A failing decrypt row. The store's error taxonomy is closed and path-free, so naming the reason
  /// is safe; the stored bytes never reach here, so nothing an owner should not see can.
  static func unreadable(
    provider: String,
    error: LLMCredentialStoreError
  ) -> LLMAuthDoctorResult {
    LLMAuthDoctorResult(
      value:
        "\(provider) mode=oauth credential unreadable (\(reason(error))); run: clawd auth login",
      ok: false
    )
  }

  static func reason(_ error: LLMCredentialStoreError) -> String {
    switch error {
    case .missingRuntimeKey: "runtime key missing"
    case .insecureStorage: "insecure storage"
    case .malformedStorage: "malformed"
    case .unsupportedVersion: "unsupported version"
    case .oversizedStorage: "oversized"
    case .publicationFailed, .commitUncertain: "unreadable"
    }
  }
}
