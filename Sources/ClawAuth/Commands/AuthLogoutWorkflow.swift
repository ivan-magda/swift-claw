import ClawCore
import Foundation

public struct AuthLogoutWorkflow: Sendable {
  private let coordinator: AuthMutationCoordinator
  private let makeCredentialStore: @Sendable () throws -> any LLMCredentialStore

  public init(
    mutationLock: any AuthMutationLocking,
    makeCredentialStore: @escaping @Sendable () throws -> any LLMCredentialStore
  ) {
    coordinator = AuthMutationCoordinator(lock: mutationLock)
    self.makeCredentialStore = makeCredentialStore
  }

  public func logout() -> AuthCommandResult {
    switch coordinator.acquire() {
    case .failure(let failure):
      return AuthCommandResultMapper.result(for: failure)
    case .success(let lease):
      defer { lease.release() }
      return runLogout()
    }
  }
}

// MARK: - The Logout Sequence

private extension AuthLogoutWorkflow {
  func runLogout() -> AuthCommandResult {
    let store: any LLMCredentialStore
    do {
      store = try makeCredentialStore()
    } catch {
      return AuthCommandResultMapper.credentialStoreResult(for: error)
    }

    // Asked before it is deleted, so an absent record is answered rather than repaired: `delete`
    // alone would demand a runtime key this state root may never have had.
    do {
      guard try store.load(providerID: ChatGPTProviderMetadata.providerID) != nil else {
        return AuthCommandResult(
          exit: .success,
          events: [
            .output(
              "No stored \(ChatGPTProviderMetadata.providerID.rawValue) credential — already logged out."
            )
          ]
        )
      }
      try store.delete(providerID: ChatGPTProviderMetadata.providerID)
    } catch {
      return AuthCommandResultMapper.result(for: error)
    }

    return AuthCommandResult(
      exit: .success,
      events: [
        .output("Removed the stored \(ChatGPTProviderMetadata.providerID.rawValue) credential."),
        .output(
          """
          This is a local deletion, not a server-side revocation: an access token already issued \
          may stay valid until it expires.
          """
        ),
      ]
    )
  }
}
