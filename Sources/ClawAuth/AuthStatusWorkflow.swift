import ClawCore
import Foundation

/// `status`, with no CLI in it.
///
/// A read, and only a read. No lock, because an owner must be able to ask what the running daemon is
/// using without fighting it for the state root; no network and no refresh, because the answer to
/// "what is stored" is on the disk, and spending a refresh token to answer it would change the thing
/// being reported. Neither a lock nor a transport is a dependency this type has, so neither is
/// something a later change can reach for by accident.
public struct AuthStatusWorkflow: Sendable {
  private let bootstrap: AuthBootstrap
  private let makeCredentialStore: @Sendable () throws -> any LLMCredentialStore
  private let wallDate: @Sendable () -> Date

  public init(
    bootstrap: AuthBootstrap,
    makeCredentialStore: @escaping @Sendable () throws -> any LLMCredentialStore,
    wallDate: @escaping @Sendable () -> Date
  ) {
    self.bootstrap = bootstrap
    self.makeCredentialStore = makeCredentialStore
    self.wallDate = wallDate
  }

  public func status() -> AuthCommandResult {
    let store: any LLMCredentialStore
    do {
      store = try makeCredentialStore()
    } catch {
      return AuthCommandResultMapper.credentialStoreResult(for: error)
    }

    let stored: StoredOAuthCredential?
    do {
      stored = try store.load(providerID: ChatGPTProviderMetadata.providerID)
    } catch {
      return AuthCommandResultMapper.result(for: error)
    }

    var events: [AuthPresentationEvent] = [
      .output("provider: \(ChatGPTProviderMetadata.providerID.rawValue)")
    ]

    guard let stored else {
      events.append(.output("credential: none — logged out. Run `clawd auth login`."))
      return AuthCommandResult(exit: .success, events: events)
    }

    events.append(.output("credential: present"))
    events.append(
      .output(
        "expires: \(Self.expiry(stored.expiresAt)) "
          + "(\(Self.label(for: freshness(of: stored))))"
      )
    )
    if let model = ModelSelection.qualifiedChatGPTModel(in: bootstrap.configuredModel) {
      events.append(.output("model: \(model)"))
    }
    return AuthCommandResult(exit: .success, events: events)
  }
}

// MARK: - Wording

private extension AuthStatusWorkflow {
  /// UTC and locale-free: an expiry an owner reads has to mean the same instant as the one the
  /// vendor issued, whatever the host's region is set to.
  static func expiry(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  /// Read through the one classifier the runtime credential source and doctor also read through. A
  /// second rule here would let an owner be told a token is fresh while the source about to spend it
  /// decides otherwise.
  func freshness(of credential: StoredOAuthCredential) -> ChatGPTCredentialFreshness {
    ChatGPTCredentialFreshness.classify(expiresAt: credential.expiresAt, now: wallDate())
  }

  static func label(for freshness: ChatGPTCredentialFreshness) -> String {
    switch freshness {
    case .fresh:
      return "fresh"
    case .expiring:
      return "expiring"
    case .expired:
      return "expired"
    }
  }
}
