import ClawCore
import Synchronization

/// A credential store that records every write and answers with whatever failure a test last set.
/// The synchronous seam is lock-backed so tests observe the same suspension-free publication
/// boundary as production.
public final class RecordingLLMCredentialStore: LLMCredentialStore, Sendable {
  private struct Ledger {
    var saved: [StoredOAuthCredential] = []
    var failure: LLMCredentialStoreError?
  }

  private let ledger = Mutex(Ledger())

  public init(failing failure: LLMCredentialStoreError? = nil) {
    ledger.withLock { current in
      current.failure = failure
    }
  }

  public var saved: [StoredOAuthCredential] {
    ledger.withLock { current in
      current.saved
    }
  }

  /// Every accepted write, including writes the script rejects.
  public var saveAttempts: Int { saved.count }

  public func stopFailing() {
    ledger.withLock { current in
      current.failure = nil
    }
  }

  public func load(
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    nil
  }

  public func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {
    let failure = ledger.withLock { current -> LLMCredentialStoreError? in
      current.saved.append(credential)
      return current.failure
    }
    if let failure {
      throw failure
    }
  }

  public func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {}
}
