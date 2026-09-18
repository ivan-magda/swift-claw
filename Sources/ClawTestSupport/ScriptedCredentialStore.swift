import ClawCore
import Synchronization

/// Returns a fixed credential or typed failure and counts every load, including failed loads.
/// Writes are ignored so the script remains unchanged throughout a test.
package final class ScriptedCredentialStore: LLMCredentialStore {
  package enum Behavior: Sendable {
    case value(StoredOAuthCredential?)
    case failure(LLMCredentialStoreError)
  }

  private let behavior: Behavior
  private let loads = Mutex(0)

  package init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  package var loadCount: Int {
    loads.withLock { count in
      count
    }
  }

  package func load(
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    loads.withLock { count in
      count += 1
    }
    switch behavior {
    case .value(let credential):
      return credential
    case .failure(let error):
      throw error
    }
  }

  package func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {}

  package func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {}
}
