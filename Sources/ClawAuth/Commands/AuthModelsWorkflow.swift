import ClawCore
import Foundation

/// Lists the models the stored subscription credential may name, without changing anything.
///
/// It is a read, like status: no lock, no refresh, no save. The running daemon is the only process
/// allowed to rotate a credential, so this spends the stored access token as it is and declines when
/// that token has already expired rather than renewing it behind the daemon's back.
public struct AuthModelsWorkflow: Sendable {
  private let bootstrap: AuthBootstrap
  private let makeCredentialStore: @Sendable () throws -> any LLMCredentialStore
  private let catalog: any ChatGPTModelCatalogFetching
  private let wallDate: @Sendable () -> Date

  public init(
    bootstrap: AuthBootstrap,
    makeCredentialStore: @escaping @Sendable () throws -> any LLMCredentialStore,
    catalog: any ChatGPTModelCatalogFetching,
    wallDate: @escaping @Sendable () -> Date
  ) {
    self.bootstrap = bootstrap
    self.makeCredentialStore = makeCredentialStore
    self.catalog = catalog
    self.wallDate = wallDate
  }

  public func models() async -> AuthCommandResult {
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

    guard let stored else {
      return Self.failure("No stored credential. Run `clawd auth login` first.")
    }

    let freshness = ChatGPTCredentialFreshness.classify(
      expiresAt: stored.expiresAt,
      now: wallDate()
    )
    guard freshness != .expired else {
      return Self.failure(
        """
        The stored access token has expired, and this command does not renew it. Send the bot a \
        message so the running daemon renews it, or stop clawd and run `clawd auth login`.
        """
      )
    }

    let models: [ChatGPTCatalogModel]
    do {
      models = try await catalog.fetch(
        authorization: ChatGPTProviderMetadata.authorization(
          accessToken: stored.accessToken,
          generation: .zero
        )
      )
    } catch let failure as ChatGPTCatalogFailure {
      return Self.failure("The model list could not be read — \(failure.safeDetail).")
    } catch {
      return Self.failure("The model list could not be read.")
    }

    return AuthCommandResult(exit: .success, events: listingEvents(for: models))
  }
}

// MARK: - Wording

private extension AuthModelsWorkflow {
  static func failure(_ message: String) -> AuthCommandResult {
    AuthCommandResult(exit: .commandFailure, events: [.error(message)])
  }

  /// Qualified references, so any row can be pasted as the value of the model variable as printed.
  /// The configured row is marked through the same reading status uses, so a model this lists as
  /// configured is the one the daemon would resolve at boot.
  func listingEvents(for models: [ChatGPTCatalogModel]) -> [AuthPresentationEvent] {
    guard !models.isEmpty else {
      return [.output("The provider offered no eligible models.")]
    }

    let configured = ModelSelection.configuredChatGPTSuffix(in: bootstrap.configuredModel)
    var events: [AuthPresentationEvent] = [.output("Available models:")]

    for model in models {
      let marker = model.slug == configured ? " (configured)" : ""
      events.append(.output("  \(ChatGPTProviderMetadata.modelPrefix)\(model.slug)\(marker)"))
    }

    events.append(.output("Set one in your environment:"))
    events.append(.output("    \(ModelSelection.manualAssignmentForm)"))

    return events
  }
}
